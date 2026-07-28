const std = @import("std");
const raw = @import("raw.zig").c;

/// Retained I/O ownership after a transport failure could not be reported to
/// the native operation. The parent State is the implicit IoItem state.
pub const PendingItem = struct {
    handle: *const raw.turso_sync_io_item_t,
    terminal: bool,
    status_set: bool,
    poison_message: []const u8,
};

/// Heap-stable owner state shared by the public database value and every
/// operation, connection, and checked-out I/O item derived from it.
pub const State = struct {
    allocator: std.mem.Allocator,
    handle: *const raw.turso_sync_database_t,
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    operation_handle: ?*const raw.turso_sync_operation_t = null,
    operation_needs_io: bool = false,
    outstanding_items: usize = 0,
    pending_item: ?PendingItem = null,
};
