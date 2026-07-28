const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("../status.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const ffi = @import("../ffi.zig");
const runtime = @import("../runtime.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const operation_mod = @import("operation.zig");
const io_mod = @import("io.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Error = status_mod.Error;
pub const LocalConfig = config_mod.LocalConfig;
pub const SyncConfig = config_mod.SyncConfig;
pub const PartialBootstrap = config_mod.PartialBootstrap;
pub const Connection = operation_mod.Connection;
pub const Changes = operation_mod.Changes;
pub const Stats = operation_mod.Stats;
pub const IoItem = io_mod.IoItem;

/// Move-only owner of the native synced database and heap-stable child counts.
/// All methods are single-thread exclusive except use of an extracted
/// Connection, whose own safe API governs its exclusivity.
pub const SyncDatabase = struct {
    state: ?*state_mod.State,

    pub fn new(
        allocator: std.mem.Allocator,
        local: LocalConfig,
        sync_config: SyncConfig,
        diagnostics: ?*Diagnostics,
    ) !SyncDatabase {
        try runtime.verifyRuntimeVersion(diagnostics);
        var native_config = try config_mod.NativeConfig.init(
            allocator,
            local,
            sync_config,
            diagnostics,
        );
        defer native_config.deinit();

        var handle: ?*const raw.turso_sync_database_t = null;
        var native_error: ffi.NativeError = null;
        ffi.expect(
            raw.turso_sync_database_new(
                &native_config.base,
                &native_config.sync,
                &handle,
                &native_error,
            ),
            native_error,
            .ok,
            diagnostics,
            "sync database constructor returned an unexpected control status",
        ) catch |err| {
            if (handle) |partial| raw.turso_sync_database_deinit(partial);
            return err;
        };
        if (handle == null) {
            ffi.setWrapperError(diagnostics, "sync database constructor returned a null handle");
            return error.InvalidState;
        }
        errdefer raw.turso_sync_database_deinit(handle.?);

        const state = try allocator.create(state_mod.State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .handle = handle.?,
        };
        return .{ .state = state };
    }

    pub fn open(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(void) {
        return self.begin(void, raw.turso_sync_database_open, diagnostics);
    }

    pub fn create(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(void) {
        return self.begin(void, raw.turso_sync_database_create, diagnostics);
    }

    pub fn connect(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(Connection) {
        return self.begin(Connection, raw.turso_sync_database_connect, diagnostics);
    }

    pub fn stats(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(Stats) {
        return self.begin(Stats, raw.turso_sync_database_stats, diagnostics);
    }

    pub fn checkpoint(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(void) {
        return self.begin(void, raw.turso_sync_database_checkpoint, diagnostics);
    }

    pub fn push(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(void) {
        return self.begin(void, raw.turso_sync_database_push_changes, diagnostics);
    }

    pub fn wait(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!operation_mod.Operation(?Changes) {
        return self.begin(?Changes, raw.turso_sync_database_wait_changes, diagnostics);
    }

    /// Consume `changes` before crossing C, matching the pinned ABI even when
    /// native operation creation fails.
    pub fn apply(
        self: *SyncDatabase,
        changes: *Changes,
        diagnostics: ?*Diagnostics,
    ) Error!operation_mod.Operation(void) {
        const state = try self.requireIdle(diagnostics);
        const native_changes = changes.handle orelse {
            ffi.setWrapperError(diagnostics, "sync changes are already consumed or deinited");
            return error.InvalidState;
        };
        changes.handle = null;
        var handle: ?*const raw.turso_sync_operation_t = null;
        var native_error: ffi.NativeError = null;
        ffi.expect(
            raw.turso_sync_database_apply_changes(
                state.handle,
                native_changes,
                &handle,
                &native_error,
            ),
            native_error,
            .ok,
            diagnostics,
            "sync apply returned an unexpected control status",
        ) catch |err| {
            if (handle) |partial| raw.turso_sync_operation_deinit(partial);
            return err;
        };
        if (handle == null) {
            ffi.setWrapperError(diagnostics, "sync apply returned a null operation");
            return error.InvalidState;
        }
        return operation_mod.initInternal(void, state, handle.?, diagnostics);
    }

    pub fn takeIoItem(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!?IoItem {
        const state = self.state orelse {
            ffi.setWrapperError(diagnostics, "sync database is already deinited");
            return error.InvalidState;
        };
        if (state.operation_handle == null) {
            ffi.setWrapperError(diagnostics, "sync I/O can be drained only while an operation is active");
            return error.InvalidState;
        }
        if (!state.operation_needs_io) {
            ffi.setWrapperError(diagnostics, "sync I/O can be drained only after operation poll requests I/O");
            return error.InvalidState;
        }
        return io_mod.take(state, diagnostics);
    }

    pub fn stepIoCallbacks(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!void {
        const state = self.state orelse {
            ffi.setWrapperError(diagnostics, "sync database is already deinited");
            return error.InvalidState;
        };
        if (state.operation_handle == null) {
            ffi.setWrapperError(diagnostics, "sync I/O callbacks require an active operation");
            return error.InvalidState;
        }
        if (!state.operation_needs_io) {
            ffi.setWrapperError(diagnostics, "sync I/O callbacks require an operation waiting for I/O");
            return error.InvalidState;
        }
        if (state.outstanding_items != 0) {
            ffi.setWrapperError(diagnostics, "sync I/O callbacks cannot run with checked-out items");
            return error.InvalidState;
        }
        var native_error: ffi.NativeError = null;
        try ffi.expect(
            raw.turso_sync_database_io_step_callbacks(state.handle, &native_error),
            native_error,
            .ok,
            diagnostics,
            "sync I/O callback step returned an unexpected control status",
        );
    }

    /// Checked release. A live operation, I/O item, or adopted connection
    /// leaves this owner valid so children can be released and close retried.
    pub fn close(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!void {
        const state = self.state orelse {
            ffi.setWrapperError(diagnostics, "sync database is already closed");
            return error.InvalidState;
        };
        if (state.operation_handle != null or
            state.operation_needs_io or
            state.outstanding_items != 0 or
            state.pending_item != null)
        {
            ffi.setWrapperError(diagnostics, "sync database cannot close with a live operation or I/O item");
            return error.InvalidState;
        }
        if (state.active_connections.load(.acquire) != 0) {
            ffi.setWrapperError(diagnostics, "sync database cannot close with live connections");
            return error.InvalidState;
        }
        raw.turso_sync_database_deinit(state.handle);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.state = null;
        if (diagnostics) |value| value.clear();
    }

    /// Infallible release after the lifecycle preconditions are satisfied.
    /// Repeated calls after `close` or `deinit` are no-ops.
    pub fn deinit(self: *SyncDatabase) void {
        if (self.state == null) return;
        self.close(null) catch {
            @panic("SyncDatabase.deinit called with a live operation, I/O item, or adopted connection");
        };
    }

    fn begin(
        self: *SyncDatabase,
        comptime T: type,
        comptime native_begin: anytype,
        diagnostics: ?*Diagnostics,
    ) Error!operation_mod.Operation(T) {
        const state = try self.requireIdle(diagnostics);
        var handle: ?*const raw.turso_sync_operation_t = null;
        var native_error: ffi.NativeError = null;
        ffi.expect(
            native_begin(state.handle, &handle, &native_error),
            native_error,
            .ok,
            diagnostics,
            "sync operation constructor returned an unexpected control status",
        ) catch |err| {
            if (handle) |partial| raw.turso_sync_operation_deinit(partial);
            return err;
        };
        if (handle == null) {
            ffi.setWrapperError(diagnostics, "sync operation constructor returned a null handle");
            return error.InvalidState;
        }
        return operation_mod.initInternal(T, state, handle.?, diagnostics);
    }

    fn requireIdle(self: *SyncDatabase, diagnostics: ?*Diagnostics) Error!*state_mod.State {
        const state = self.state orelse {
            ffi.setWrapperError(diagnostics, "sync database is already deinited");
            return error.InvalidState;
        };
        if (state.operation_handle != null or state.pending_item != null) {
            ffi.setWrapperError(diagnostics, "sync database already owns an active operation");
            return error.InvalidState;
        }
        if (state.outstanding_items != 0) {
            ffi.setWrapperError(diagnostics, "sync database has a checked-out I/O item");
            return error.InvalidState;
        }
        return state;
    }
};
