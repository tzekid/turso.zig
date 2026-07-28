//! Common synchronous workflows over the caller-owned sync transport.
//!
//! These helpers compose the existing checked Operation lifecycle. They do not
//! add scheduling, cancellation, conflict retries, or distributed transaction
//! semantics. `transport.run` and every low-level owner remain available.

const std = @import("std");
const database_mod = @import("database.zig");
const operation_mod = @import("operation.zig");
const transport_mod = @import("transport.zig");

pub const Diagnostics = database_mod.Diagnostics;
pub const SyncDatabase = database_mod.SyncDatabase;
pub const Connection = operation_mod.Connection;
pub const Changes = operation_mod.Changes;
pub const Operation = operation_mod.Operation;
pub const TransportOptions = transport_mod.Options;

pub const PullSummary = struct {
    changes_received: bool,
    changes_applied: bool,
};

pub const SyncSummary = struct {
    push_completed: bool,
    pull: PullSummary,
};

/// Drive a caller-owned void operation without repeating its result type.
///
/// The pointer deliberately remains caller-owned: if native I/O-item recovery
/// itself fails, retry this helper (or `transport.run`) with the same
/// Operation. Ordinary completion and operation failures close it.
pub fn runVoid(
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    operation: *Operation(void),
    transport: anytype,
    options: TransportOptions,
) !void {
    return transport_mod.run(
        void,
        allocator,
        database,
        operation,
        transport,
        options,
    );
}

/// Drive a caller-owned connection operation without repeating its result
/// type. The returned Connection remains a normal child of `database`.
pub fn runConnection(
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    operation: *Operation(Connection),
    transport: anytype,
    options: TransportOptions,
) !Connection {
    return transport_mod.run(
        Connection,
        allocator,
        database,
        operation,
        transport,
        options,
    );
}

/// Wait for remote changes and apply them when present.
///
/// A successful no-change result sets both fields false. A successful apply
/// sets both true. Changes are consumed or released on every ordinary error
/// path; no conflict or cancellation retry is performed.
pub fn pull(
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    transport: anytype,
    options: TransportOptions,
) !PullSummary {
    var wait_operation = try database.wait(options.diagnostics);
    var maybe_changes = try transport_mod.run(
        ?Changes,
        allocator,
        database,
        &wait_operation,
        transport,
        options,
    );
    if (maybe_changes) |*changes| {
        defer changes.deinit();
        var apply_operation = try database.apply(changes, options.diagnostics);
        try runVoid(
            allocator,
            database,
            &apply_operation,
            transport,
            options,
        );
        return .{
            .changes_received = true,
            .changes_applied = true,
        };
    }
    return .{
        .changes_received = false,
        .changes_applied = false,
    };
}

/// Push local changes, then wait for and conditionally apply remote changes.
///
/// This is an orchestration convenience only. The two directions are separate
/// sync operations, not a distributed transaction, and Busy/BusySnapshot or
/// conflict outcomes are never retried automatically.
pub fn sync(
    allocator: std.mem.Allocator,
    database: *SyncDatabase,
    transport: anytype,
    options: TransportOptions,
) !SyncSummary {
    var push_operation = try database.push(options.diagnostics);
    try runVoid(
        allocator,
        database,
        &push_operation,
        transport,
        options,
    );
    return .{
        .push_completed = true,
        .pull = try pull(allocator, database, transport, options),
    };
}
