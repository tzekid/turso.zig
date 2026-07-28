//! Transport-neutral sync I/O dispatch and deterministic operation driving.
//!
//! A transport implementation is a caller-owned value with these methods:
//!
//! - `request(HttpRequest, *ResponseWriter) !void`
//! - `readFile(path, *BufferWriter) !void`
//! - `writeFileAtomically(path, content) !void`
//!
//! The methods run synchronously. They may stream response/file bytes through
//! the supplied writer. Transport errors are deliberately replaced with fixed
//! poison categories before crossing the native boundary.

const std = @import("std");
const database_mod = @import("database.zig");
const operation_mod = @import("operation.zig");
const io_mod = @import("io.zig");
const state_mod = @import("state.zig");

pub const Diagnostics = database_mod.Diagnostics;
pub const SyncDatabase = database_mod.SyncDatabase;
pub const IoItem = io_mod.IoItem;

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Borrowed request data. Every slice expires when the current transport call
/// returns. `authorization` is explicit so adapters can give it stricter
/// redirect handling and must never include it in errors or diagnostics.
pub const HttpRequest = struct {
    url: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    headers: []const HttpHeader,
    authorization: ?HttpHeader,
};

pub const Options = struct {
    /// Optional caller-owned authorization header injected in addition to
    /// every native request header. Its bytes are never copied to diagnostics.
    authorization: ?HttpHeader = null,
    diagnostics: ?*Diagnostics = null,
};

/// Streams response data into one checked-out native I/O item.
pub const BufferWriter = struct {
    item: *IoItem,
    diagnostics: ?*Diagnostics,

    pub fn push(self: *BufferWriter, bytes: []const u8) !void {
        try self.item.pushBuffer(bytes, self.diagnostics);
    }
};

/// HTTP response sink. Status is protocol data, including non-2xx values, and
/// must be set exactly once before the transport returns successfully.
pub const ResponseWriter = struct {
    buffer: BufferWriter,

    pub fn setStatus(self: *ResponseWriter, status: u32) !void {
        const value = std.math.cast(u16, status) orelse {
            if (self.buffer.diagnostics) |diagnostics| {
                diagnostics.setWrapperError("sync HTTP transport returned an invalid status");
            }
            return error.InvalidHttpStatus;
        };
        try self.buffer.item.status(value, self.buffer.diagnostics);
    }

    pub fn push(self: *ResponseWriter, bytes: []const u8) !void {
        try self.buffer.push(bytes);
    }
};

const poison_http = "sync transport HTTP failure";
const poison_full_read = "sync transport full-read failure";
const poison_full_write = "sync transport full-write failure";
const poison_request = "sync transport request failure";

/// Drive `operation` to completion, drain every queued I/O item on each round,
/// extract its typed result, and deinitialize the native operation.
///
/// The transport is borrowed and owns its resources explicitly. A successfully
/// checked-out item is always completed or poisoned and then deinitialized
/// before callbacks are stepped.
pub fn run(
    comptime T: type,
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    operation: *operation_mod.Operation(T),
    transport: anytype,
    options: Options,
) !T {
    const state = try operation_mod.stateForRun(T, operation, options.diagnostics);
    var deferred_callback_error: ?anyerror = null;
    while (true) {
        if (operation_mod.hasPending(state)) {
            _ = try operation_mod.releasePending(state, options.diagnostics);
            database.stepIoCallbacks(options.diagnostics) catch |err| {
                if (deferred_callback_error == null) {
                    deferred_callback_error = err;
                }
            };
        }

        const poll = operation.poll(options.diagnostics) catch |err| {
            operation.close(null) catch |cleanup_err| return cleanup_err;
            operation.deinit();
            return err;
        };
        switch (poll) {
            .done => {
                var result = operation.finish(options.diagnostics) catch |err| {
                    operation.close(null) catch |cleanup_err| return cleanup_err;
                    operation.deinit();
                    return err;
                };
                operation.close(options.diagnostics) catch |err| {
                    cleanupResult(T, &result);
                    return err;
                };
                operation.deinit();
                if (deferred_callback_error) |err| {
                    cleanupResult(T, &result);
                    return err;
                }
                return result;
            },
            .io => {
                try drainIo(allocator, database, state, transport, options);
                database.stepIoCallbacks(options.diagnostics) catch |err| {
                    // Resume once more so the native operation can enter its
                    // terminal failed state and remain legally deinitializable.
                    // If it instead converges to done, return this first
                    // callback error after releasing the typed result.
                    if (deferred_callback_error == null) {
                        deferred_callback_error = err;
                    }
                };
            },
        }
    }
}

fn drainIo(
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    state: *state_mod.State,
    transport: anytype,
    options: Options,
) !void {
    while (try database.takeIoItem(options.diagnostics)) |taken| {
        var item = taken;
        const kind = item.requestKind(options.diagnostics) catch |request_err| {
            try poisonOrRetain(state, &item, poison_request, request_err, options);
            try item.close(options.diagnostics);
            item.deinit();
            continue;
        };

        dispatchItem(allocator, &item, kind, transport, options) catch |transport_err| {
            const category = switch (kind) {
                .http => poison_http,
                .full_read => poison_full_read,
                .full_write => poison_full_write,
            };
            try poisonOrRetain(state, &item, category, transport_err, options);
        };
        try item.close(options.diagnostics);
        item.deinit();
    }
}

fn poisonOrRetain(
    state: *state_mod.State,
    item: *IoItem,
    category: []const u8,
    first_error: anyerror,
    options: Options,
) !void {
    item.poison(category, options.diagnostics) catch {
        if (options.diagnostics) |diagnostics| {
            diagnostics.setWrapperError(category);
        }
        operation_mod.retainIoItem(state, item, category);
        return first_error;
    };
}

fn dispatchItem(
    allocator: std.mem.Allocator,
    item: *IoItem,
    kind: io_mod.RequestKind,
    transport: anytype,
    options: Options,
) !void {
    switch (kind) {
        .http => {
            const native_request = try item.http(options.diagnostics);
            const headers = try allocator.alloc(HttpHeader, native_request.header_count);
            defer allocator.free(headers);
            for (headers, 0..) |*header, index| {
                const native_header = try item.httpHeader(index, options.diagnostics);
                header.* = .{
                    .name = native_header.key,
                    .value = native_header.value,
                };
            }

            var writer = ResponseWriter{ .buffer = .{
                .item = item,
                .diagnostics = options.diagnostics,
            } };
            try transport.request(.{
                .url = native_request.url,
                .method = native_request.method,
                .path = native_request.path,
                .body = native_request.body,
                .headers = headers,
                .authorization = options.authorization,
            }, &writer);
            if (!item.status_set) return error.MissingHttpStatus;
            try item.done(options.diagnostics);
        },
        .full_read => {
            const request = try item.fullRead(options.diagnostics);
            var writer = BufferWriter{
                .item = item,
                .diagnostics = options.diagnostics,
            };
            try transport.readFile(request.path, &writer);
            try item.done(options.diagnostics);
        },
        .full_write => {
            const request = try item.fullWrite(options.diagnostics);
            try transport.writeFileAtomically(request.path, request.content);
            try item.done(options.diagnostics);
        },
    }
}

fn cleanupResult(comptime T: type, result: *T) void {
    if (T == void) {
        return;
    } else if (T == operation_mod.Connection) {
        result.deinit();
    } else if (T == ?operation_mod.Changes) {
        if (result.*) |*changes| changes.deinit();
        result.* = null;
    } else if (T == operation_mod.Stats) {
        result.deinit();
    } else {
        unreachable;
    }
}

test {
    _ = BufferWriter;
    _ = ResponseWriter;
}
