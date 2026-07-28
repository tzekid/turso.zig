const std = @import("std");
const builtin = @import("builtin");
const raw = @import("raw.zig").c;
const status_mod = @import("../status.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const ffi = @import("../ffi.zig");
const invariant = @import("../invariant.zig");
const state_mod = @import("state.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Error = status_mod.Error;

pub const RequestKind = enum {
    http,
    full_read,
    full_write,
};

pub const HttpRequest = struct {
    url: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    header_count: usize,
};

pub const HttpHeader = struct {
    key: []const u8,
    value: []const u8,
};

pub const FullReadRequest = struct {
    path: []const u8,
};

pub const FullWriteRequest = struct {
    path: []const u8,
    content: []const u8,
};

/// Exclusive owner of one sync-engine queue item. Every returned slice borrows
/// from this item and expires when `close` succeeds.
pub const IoItem = struct {
    state: ?*state_mod.State,
    handle: ?*const raw.turso_sync_io_item_t,
    terminal: bool = false,
    status_set: bool = false,

    pub fn requestKind(self: *const IoItem, diagnostics: ?*Diagnostics) Error!RequestKind {
        const handle = try self.requireOpen(diagnostics);
        return switch (raw.turso_sync_database_io_request_kind(handle)) {
            raw.TURSO_SYNC_IO_HTTP => .http,
            raw.TURSO_SYNC_IO_FULL_READ => .full_read,
            raw.TURSO_SYNC_IO_FULL_WRITE => .full_write,
            else => {
                ffi.setWrapperError(diagnostics, "sync I/O item returned an unknown or empty request kind");
                return error.InvalidState;
            },
        };
    }

    pub fn http(self: *const IoItem, diagnostics: ?*Diagnostics) Error!HttpRequest {
        const handle = try self.requireKind(.http, diagnostics);
        var request = std.mem.zeroes(raw.turso_sync_io_http_request_t);
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_request_http(handle, &request),
            .ok,
            diagnostics,
            "native sync I/O HTTP request extraction failed",
        );
        if (request.headers < 0) {
            ffi.setWrapperError(diagnostics, "native sync I/O HTTP request returned a negative header count");
            return error.InvalidState;
        }
        return .{
            .url = try borrowedSlice(request.url, diagnostics),
            .method = try borrowedSlice(request.method, diagnostics),
            .path = try borrowedSlice(request.path, diagnostics),
            .body = try borrowedSlice(request.body, diagnostics),
            .header_count = @intCast(request.headers),
        };
    }

    pub fn httpHeader(
        self: *const IoItem,
        index: usize,
        diagnostics: ?*Diagnostics,
    ) Error!HttpHeader {
        const request = try self.http(diagnostics);
        if (index >= request.header_count) {
            ffi.setWrapperError(diagnostics, "sync I/O HTTP header index is out of bounds");
            return error.ColumnOutOfBounds;
        }
        const handle = self.handle.?;
        var header = std.mem.zeroes(raw.turso_sync_io_http_header_t);
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_request_http_header(handle, index, &header),
            .ok,
            diagnostics,
            "native sync I/O HTTP header extraction failed",
        );
        return .{
            .key = try borrowedSlice(header.key, diagnostics),
            .value = try borrowedSlice(header.value, diagnostics),
        };
    }

    pub fn fullRead(self: *const IoItem, diagnostics: ?*Diagnostics) Error!FullReadRequest {
        const handle = try self.requireKind(.full_read, diagnostics);
        var request = std.mem.zeroes(raw.turso_sync_io_full_read_request_t);
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_request_full_read(handle, &request),
            .ok,
            diagnostics,
            "native sync full-read request extraction failed",
        );
        return .{ .path = try borrowedSlice(request.path, diagnostics) };
    }

    pub fn fullWrite(self: *const IoItem, diagnostics: ?*Diagnostics) Error!FullWriteRequest {
        const handle = try self.requireKind(.full_write, diagnostics);
        var request = std.mem.zeroes(raw.turso_sync_io_full_write_request_t);
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_request_full_write(handle, &request),
            .ok,
            diagnostics,
            "native sync full-write request extraction failed",
        );
        return .{
            .path = try borrowedSlice(request.path, diagnostics),
            .content = try borrowedSlice(request.content, diagnostics),
        };
    }

    pub fn status(self: *IoItem, value: u16, diagnostics: ?*Diagnostics) Error!void {
        const handle = try self.requireCompletable(diagnostics);
        if (try self.requestKind(diagnostics) != .http) {
            ffi.setWrapperError(diagnostics, "HTTP completion status is valid only for HTTP requests");
            return error.InvalidState;
        }
        if (self.status_set) {
            ffi.setWrapperError(diagnostics, "sync HTTP completion status was already submitted");
            return error.InvalidState;
        }
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_status(handle, value),
            .ok,
            diagnostics,
            "native sync I/O status completion failed",
        );
        self.status_set = true;
    }

    pub fn pushBuffer(self: *IoItem, bytes: []const u8, diagnostics: ?*Diagnostics) Error!void {
        const handle = try self.requireCompletable(diagnostics);
        var slice = nativeSlice(bytes);
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_push_buffer(handle, &slice),
            .ok,
            diagnostics,
            "native sync I/O buffer completion failed",
        );
    }

    pub fn done(self: *IoItem, diagnostics: ?*Diagnostics) Error!void {
        const handle = try self.requireCompletable(diagnostics);
        if (try self.requestKind(diagnostics) == .http and !self.status_set) {
            ffi.setWrapperError(diagnostics, "sync HTTP request requires a completion status before done");
            return error.InvalidState;
        }
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_done(handle),
            .ok,
            diagnostics,
            "native sync I/O completion failed",
        );
        self.terminal = true;
    }

    pub fn poison(self: *IoItem, message: []const u8, diagnostics: ?*Diagnostics) Error!void {
        const handle = try self.requireCompletable(diagnostics);
        if (!std.unicode.utf8ValidateSlice(message)) {
            ffi.setWrapperError(diagnostics, "sync transport error must be valid UTF-8");
            return error.InvalidUtf8;
        }
        var slice = nativeSlice(message);
        const inject_native_failure = if (builtin.is_test)
            if (diagnostics) |value|
                std.mem.eql(u8, value.text(), native_poison_failure_marker)
            else
                false
        else
            false;
        if (inject_native_failure) {
            slice.ptr = null;
        }
        try ffi.expectWithoutMessage(
            raw.turso_sync_database_io_poison(handle, &slice),
            .ok,
            diagnostics,
            "native sync I/O poison completion failed",
        );
        self.terminal = true;
    }

    /// Checked release after `done` or `poison`. A precondition failure leaves
    /// the checked-out item valid for completion and retry.
    pub fn close(self: *IoItem, diagnostics: ?*Diagnostics) Error!void {
        const handle = self.handle orelse {
            ffi.setWrapperError(diagnostics, "sync I/O item is already closed");
            return error.InvalidState;
        };
        if (!self.terminal) {
            ffi.setWrapperError(diagnostics, "sync I/O item must be completed or poisoned before close");
            return error.InvalidState;
        }
        const state = self.state orelse return error.InvalidState;
        invariant.requireOutstandingSyncItem(state.outstanding_items);
        raw.turso_sync_database_io_item_deinit(handle);
        state.outstanding_items -= 1;
        self.handle = null;
        self.state = null;
        if (diagnostics) |value| value.clear();
    }

    /// Infallible release after completion. Repeated calls after release are
    /// no-ops; violating the completion precondition is a programmer error.
    pub fn deinit(self: *IoItem) void {
        if (self.state == null and self.handle == null) return;
        self.close(null) catch {
            @panic("IoItem.deinit called before done or poison");
        };
    }

    fn requireOpen(self: *const IoItem, diagnostics: ?*Diagnostics) Error!*const raw.turso_sync_io_item_t {
        return self.handle orelse {
            ffi.setWrapperError(diagnostics, "sync I/O item is already deinited");
            return error.InvalidState;
        };
    }

    fn requireCompletable(self: *const IoItem, diagnostics: ?*Diagnostics) Error!*const raw.turso_sync_io_item_t {
        const handle = try self.requireOpen(diagnostics);
        if (self.terminal) {
            ffi.setWrapperError(diagnostics, "sync I/O item completion was already submitted");
            return error.InvalidState;
        }
        return handle;
    }

    fn requireKind(
        self: *const IoItem,
        expected: RequestKind,
        diagnostics: ?*Diagnostics,
    ) Error!*const raw.turso_sync_io_item_t {
        const handle = try self.requireOpen(diagnostics);
        if (try self.requestKind(diagnostics) != expected) {
            ffi.setWrapperError(diagnostics, "sync I/O request accessor does not match the native request kind");
            return error.TypeMismatch;
        }
        return handle;
    }
};

const native_poison_failure_marker = "turso.zig test: fail native poison";

pub fn take(state: *state_mod.State, diagnostics: ?*Diagnostics) Error!?IoItem {
    var handle: ?*const raw.turso_sync_io_item_t = null;
    var native_error: ffi.NativeError = null;
    ffi.expect(
        raw.turso_sync_database_io_take_item(state.handle, &handle, &native_error),
        native_error,
        .ok,
        diagnostics,
        "sync I/O queue returned an unexpected control status",
    ) catch |err| {
        if (handle) |partial| raw.turso_sync_database_io_item_deinit(partial);
        return err;
    };
    if (handle == null) return null;
    state.outstanding_items += 1;
    return .{ .state = state, .handle = handle.? };
}

fn borrowedSlice(value: raw.turso_slice_ref_t, diagnostics: ?*Diagnostics) Error![]const u8 {
    if (value.len == 0) return &.{};
    if (value.ptr == null) {
        ffi.setWrapperError(diagnostics, "native sync I/O returned a null pointer for a non-empty slice");
        return error.InvalidState;
    }
    const pointer: [*]const u8 = @ptrCast(value.ptr.?);
    return pointer[0..value.len];
}

const empty_sentinel = [_]u8{0};

fn nativeSlice(bytes: []const u8) raw.turso_slice_ref_t {
    return .{
        .ptr = if (bytes.len == 0) @ptrCast(&empty_sentinel) else @ptrCast(bytes.ptr),
        .len = bytes.len,
    };
}
