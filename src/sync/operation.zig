const std = @import("std");
const raw = @import("raw.zig").c;
const base_raw = @import("../raw.zig").c;
const status_mod = @import("../status.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const ffi = @import("../ffi.zig");
const connection_mod = @import("../connection.zig");
const state_mod = @import("state.zig");
const io_mod = @import("io.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Error = status_mod.Error;
pub const Connection = connection_mod.Connection;

pub const Poll = enum {
    io,
    done,
};

const Phase = enum {
    running,
    waiting_io,
    done,
    failed,
    extracted,
    deinited,
};

/// Preallocated, package-internal recovery owner for one Operation. The
/// curated public operation façade does not expose this type or its registry.
pub const Recovery = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.State,
    operation_handle: ?*const raw.turso_sync_operation_t = null,
    pending_item: ?io_mod.IoItem = null,
    pending_poison: ?[]const u8 = null,
    next: ?*Recovery = null,
};

var recovery_mutex: std.atomic.Mutex = .unlocked;
var recovery_head: ?*Recovery = null;

/// Owned copy of sync-engine statistics. The revision remains valid until
/// `deinit`, independently of the native Operation that produced it.
pub const Stats = struct {
    allocator: std.mem.Allocator,
    cdc_operations: i64,
    main_wal_size: i64,
    revert_wal_size: i64,
    last_pull_unix_time: i64,
    last_push_unix_time: i64,
    network_sent_bytes: i64,
    network_received_bytes: i64,
    revision: []u8,

    pub fn deinit(self: *Stats) void {
        self.allocator.free(self.revision);
        self.revision = &.{};
    }
};

/// Move-only owner of a fetched changes handle. A non-null value must be
/// deinited or consumed exactly once by `SyncDatabase.apply`.
pub const Changes = struct {
    handle: ?*const raw.turso_sync_changes_t,

    /// Release unconsumed changes. Consumption and prior release are no-ops.
    pub fn deinit(self: *Changes) void {
        const handle = self.handle orelse return;
        raw.turso_sync_changes_deinit(handle);
        self.handle = null;
    }
};

/// Typed, exclusive native operation. `T` is one of `void`, `Connection`,
/// `?Changes`, or `Stats`.
pub fn Operation(comptime T: type) type {
    comptime validateResultType(T);
    return struct {
        const Self = @This();

        state: ?*state_mod.State,
        handle: ?*const raw.turso_sync_operation_t,
        phase: Phase = .running,

        pub fn poll(self: *Self, diagnostics: ?*Diagnostics) Error!Poll {
            const state = self.state orelse {
                ffi.setWrapperError(diagnostics, "sync operation is already deinited");
                return error.InvalidState;
            };
            const handle = self.handle orelse return error.InvalidState;
            if (self.phase != .running and self.phase != .waiting_io) {
                ffi.setWrapperError(diagnostics, "sync operation cannot be resumed from its current state");
                return error.InvalidState;
            }
            if (state.outstanding_items != 0) {
                ffi.setWrapperError(diagnostics, "all checked-out sync I/O items must be completed and deinited before resume");
                return error.InvalidState;
            }

            var native_error: ffi.NativeError = null;
            const control = ffi.result(
                raw.turso_sync_operation_resume(handle, &native_error),
                native_error,
                diagnostics,
            ) catch |err| {
                self.phase = .failed;
                state.operation_needs_io = false;
                return err;
            };
            return switch (control) {
                .io => blk: {
                    self.phase = .waiting_io;
                    state.operation_needs_io = true;
                    break :blk .io;
                },
                .done => blk: {
                    self.phase = .done;
                    state.operation_needs_io = false;
                    break :blk .done;
                },
                else => {
                    self.phase = .failed;
                    state.operation_needs_io = false;
                    ffi.setWrapperError(diagnostics, "sync operation resume returned an unexpected control status");
                    return error.InvalidState;
                },
            };
        }

        /// Extract the typed result exactly once after `poll` returns `.done`.
        pub fn finish(self: *Self, diagnostics: ?*Diagnostics) Error!T {
            const state = self.state orelse {
                ffi.setWrapperError(diagnostics, "sync operation is already deinited");
                return error.InvalidState;
            };
            const handle = self.handle orelse return error.InvalidState;
            if (self.phase != .done) {
                ffi.setWrapperError(diagnostics, "sync operation result is available only after terminal done");
                return error.InvalidState;
            }

            const expected_kind = resultKind(T);
            if (raw.turso_sync_operation_result_kind(handle) != expected_kind) {
                self.phase = .failed;
                ffi.setWrapperError(diagnostics, "native sync operation result kind does not match its typed wrapper");
                return error.TypeMismatch;
            }

            if (T == void) {
                self.phase = .extracted;
                if (diagnostics) |value| value.clear();
                return {};
            } else if (T == Connection) {
                var native_connection: ?*const raw.turso_connection_t = null;
                ffi.expectWithoutMessage(
                    raw.turso_sync_operation_result_extract_connection(handle, &native_connection),
                    .ok,
                    diagnostics,
                    "native sync connection result extraction failed",
                ) catch |err| {
                    self.phase = .failed;
                    if (native_connection) |partial| base_raw.turso_connection_deinit(@ptrCast(partial));
                    return err;
                };
                if (native_connection == null) {
                    self.phase = .failed;
                    ffi.setWrapperError(diagnostics, "native sync connection result was null");
                    return error.InvalidState;
                }
                const connection = connection_mod.initWithStatementIoPolicy(
                    state.allocator,
                    @ptrCast(@constCast(native_connection.?)),
                    &state.active_connections,
                    .drive_io_inline,
                ) catch |err| {
                    base_raw.turso_connection_deinit(@ptrCast(native_connection.?));
                    self.phase = .failed;
                    ffi.setWrapperError(diagnostics, "sync connection adoption could not allocate stable owner state");
                    return err;
                };
                _ = state.active_connections.fetchAdd(1, .monotonic);
                self.phase = .extracted;
                if (diagnostics) |value| value.clear();
                return connection;
            } else if (T == ?Changes) {
                var native_changes: ?*const raw.turso_sync_changes_t = null;
                ffi.expectWithoutMessage(
                    raw.turso_sync_operation_result_extract_changes(handle, &native_changes),
                    .ok,
                    diagnostics,
                    "native sync changes result extraction failed",
                ) catch |err| {
                    self.phase = .failed;
                    if (native_changes) |partial| raw.turso_sync_changes_deinit(partial);
                    return err;
                };
                self.phase = .extracted;
                if (diagnostics) |value| value.clear();
                return if (native_changes) |value| Changes{ .handle = value } else null;
            } else if (T == Stats) {
                var native_stats = std.mem.zeroes(raw.turso_sync_stats_t);
                ffi.expectWithoutMessage(
                    raw.turso_sync_operation_result_extract_stats(handle, &native_stats),
                    .ok,
                    diagnostics,
                    "native sync stats result extraction failed",
                ) catch |err| {
                    self.phase = .failed;
                    return err;
                };
                const revision = borrowedSlice(native_stats.revision, diagnostics) catch |err| {
                    self.phase = .failed;
                    return err;
                };
                const owned_revision = state.allocator.dupe(u8, revision) catch |err| {
                    self.phase = .failed;
                    ffi.setWrapperError(diagnostics, "sync stats revision could not be copied");
                    return err;
                };
                self.phase = .extracted;
                if (diagnostics) |value| value.clear();
                return .{
                    .allocator = state.allocator,
                    .cdc_operations = native_stats.cdc_operations,
                    .main_wal_size = native_stats.main_wal_size,
                    .revert_wal_size = native_stats.revert_wal_size,
                    .last_pull_unix_time = native_stats.last_pull_unix_time,
                    .last_push_unix_time = native_stats.last_push_unix_time,
                    .network_sent_bytes = native_stats.network_sent_bytes,
                    .network_received_bytes = native_stats.network_received_bytes,
                    .revision = owned_revision,
                };
            } else unreachable;
        }

        /// Checked release after a terminal error or successful extraction.
        /// A protocol violation leaves the operation owner valid for recovery.
        pub fn close(self: *Self, diagnostics: ?*Diagnostics) Error!void {
            const state = self.state orelse {
                ffi.setWrapperError(diagnostics, "sync operation is already closed");
                return error.InvalidState;
            };
            const handle = self.handle orelse return error.InvalidState;
            const recovery = findDatabaseRecovery(state) orelse {
                ffi.setWrapperError(diagnostics, "sync operation recovery owner is unavailable");
                return error.InvalidState;
            };
            if (recovery.operation_handle != handle) {
                ffi.setWrapperError(diagnostics, "sync operation recovery owner does not match its handle");
                return error.InvalidState;
            }
            if (recovery.pending_item != null or state.outstanding_items != 0) {
                ffi.setWrapperError(diagnostics, "sync operation cannot close with a checked-out I/O item");
                return error.InvalidState;
            }
            if (self.phase != .failed and self.phase != .extracted) {
                ffi.setWrapperError(diagnostics, "sync operation must finish or fail before close");
                return error.InvalidState;
            }
            raw.turso_sync_operation_deinit(handle);
            recovery.operation_handle = null;
            std.debug.assert(state.operation_active);
            state.operation_active = false;
            state.operation_needs_io = false;
            self.phase = .deinited;
            self.handle = null;
            self.state = null;
            if (diagnostics) |value| value.clear();
        }

        /// Infallible release after the lifecycle preconditions are satisfied.
        /// Repeated calls after `close` or `deinit` are no-ops.
        pub fn deinit(self: *Self) void {
            if (self.state == null and self.handle == null) return;
            self.close(null) catch {
                @panic("Operation.deinit called before terminal extraction or with a checked-out I/O item");
            };
        }
    };
}

/// Package-internal constructor. `src/sync.zig` deliberately omits it from the
/// curated operation façade.
pub fn initInternal(
    comptime T: type,
    state: *state_mod.State,
    handle: *const raw.turso_sync_operation_t,
    diagnostics: ?*Diagnostics,
) Error!Operation(T) {
    const recovery = findDatabaseRecovery(state) orelse {
        raw.turso_sync_operation_deinit(handle);
        ffi.setWrapperError(diagnostics, "sync database recovery owner is unavailable");
        return error.InvalidState;
    };
    if (recovery.operation_handle != null or recovery.pending_item != null) {
        raw.turso_sync_operation_deinit(handle);
        ffi.setWrapperError(diagnostics, "sync database recovery owner is already active");
        return error.InvalidState;
    }
    recovery.operation_handle = handle;
    state.operation_active = true;
    state.operation_needs_io = false;
    return .{ .state = state, .handle = handle };
}

pub fn registerDatabaseRecovery(
    state: *state_mod.State,
    diagnostics: ?*Diagnostics,
) Error!void {
    const recovery = state.allocator.create(Recovery) catch |err| {
        ffi.setWrapperError(diagnostics, "sync database recovery owner could not be allocated");
        return err;
    };
    recovery.* = .{
        .allocator = state.allocator,
        .state = state,
    };
    attachRecovery(recovery);
}

pub fn unregisterDatabaseRecovery(state: *state_mod.State) void {
    const recovery = findDatabaseRecovery(state) orelse
        @panic("sync database recovery owner is unavailable");
    std.debug.assert(recovery.operation_handle == null);
    std.debug.assert(recovery.pending_item == null);
    detachRecovery(recovery);
    recovery.allocator.destroy(recovery);
}

/// Resolve the internal recovery owner before transport work begins. No
/// externally mutable recovery field participates in this lookup.
pub fn recoveryForRun(
    comptime T: type,
    operation: *Operation(T),
    diagnostics: ?*Diagnostics,
) Error!*Recovery {
    const state = operation.state orelse {
        ffi.setWrapperError(diagnostics, "sync operation is already closed");
        return error.InvalidState;
    };
    const handle = operation.handle orelse {
        ffi.setWrapperError(diagnostics, "sync operation is already closed");
        return error.InvalidState;
    };
    const recovery = findDatabaseRecovery(state) orelse {
        ffi.setWrapperError(diagnostics, "sync operation recovery owner is unavailable");
        return error.InvalidState;
    };
    if (recovery.operation_handle != handle) {
        ffi.setWrapperError(diagnostics, "sync operation recovery owner does not match its handle");
        return error.InvalidState;
    }
    return recovery;
}

pub fn hasPending(recovery: *const Recovery) bool {
    return recovery.pending_item != null;
}

pub fn retainIoItem(
    recovery: *Recovery,
    item: io_mod.IoItem,
    poison_message: []const u8,
) void {
    std.debug.assert(recovery.pending_item == null);
    std.debug.assert(recovery.pending_poison == null);
    recovery.pending_item = item;
    recovery.pending_poison = poison_message;
}

/// Retry recovery in the same stable owner. Every failure leaves both the item
/// and its poison category intact for a later `run` call.
pub fn releasePending(
    recovery: *Recovery,
    diagnostics: ?*Diagnostics,
) Error!bool {
    const item = if (recovery.pending_item) |*value| value else return false;
    const poison_message = recovery.pending_poison orelse {
        ffi.setWrapperError(diagnostics, "sync operation recovery state is incomplete");
        return error.InvalidState;
    };
    if (!item.terminal) {
        try item.poison(poison_message, diagnostics);
    }
    try item.close(diagnostics);
    item.deinit();
    recovery.pending_item = null;
    recovery.pending_poison = null;
    return true;
}

fn attachRecovery(recovery: *Recovery) void {
    lockRecovery();
    defer recovery_mutex.unlock();
    recovery.next = recovery_head;
    recovery_head = recovery;
}

fn findDatabaseRecovery(state: *state_mod.State) ?*Recovery {
    lockRecovery();
    defer recovery_mutex.unlock();
    var current = recovery_head;
    while (current) |recovery| : (current = recovery.next) {
        if (recovery.state == state) return recovery;
    }
    return null;
}

fn detachRecovery(target: *Recovery) void {
    lockRecovery();
    defer recovery_mutex.unlock();
    var previous: ?*Recovery = null;
    var current = recovery_head;
    while (current) |recovery| : (current = recovery.next) {
        if (recovery == target) {
            if (previous) |value| {
                value.next = recovery.next;
            } else {
                recovery_head = recovery.next;
            }
            recovery.next = null;
            return;
        }
        previous = recovery;
    }
    @panic("sync operation recovery registry is inconsistent");
}

fn lockRecovery() void {
    while (!recovery_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn validateResultType(comptime T: type) void {
    if (T != void and T != Connection and T != ?Changes and T != Stats) {
        @compileError("sync Operation result must be void, Connection, ?Changes, or Stats");
    }
}

fn resultKind(comptime T: type) raw.turso_sync_operation_result_type_t {
    return if (T == void)
        raw.TURSO_ASYNC_RESULT_NONE
    else if (T == Connection)
        raw.TURSO_ASYNC_RESULT_CONNECTION
    else if (T == ?Changes)
        raw.TURSO_ASYNC_RESULT_CHANGES
    else if (T == Stats)
        raw.TURSO_ASYNC_RESULT_STATS
    else
        unreachable;
}

fn borrowedSlice(value: raw.turso_slice_ref_t, diagnostics: ?*Diagnostics) Error![]const u8 {
    if (value.len == 0) return &.{};
    if (value.ptr == null) {
        ffi.setWrapperError(diagnostics, "native sync stats returned a null revision pointer for a non-empty slice");
        return error.InvalidState;
    }
    const pointer: [*]const u8 = @ptrCast(value.ptr.?);
    return pointer[0..value.len];
}
