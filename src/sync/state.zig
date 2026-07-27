const std = @import("std");
const raw = @import("raw.zig").c;

/// Heap-stable owner state shared by the public database value and every
/// operation, connection, and checked-out I/O item derived from it.
pub const State = struct {
    allocator: std.mem.Allocator,
    handle: *const raw.turso_sync_database_t,
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    operation_active: bool = false,
    operation_needs_io: bool = false,
    outstanding_items: usize = 0,
};
