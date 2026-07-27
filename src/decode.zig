const std = @import("std");
const status_mod = @import("status.zig");
const value_mod = @import("value.zig");

pub const Error = status_mod.Error || error{AllocatorRequired};

/// Decode one SQL value. Borrowed destinations never allocate. `[]u8` and
/// `OwnedValue` explicitly require an allocator and own their result.
pub fn valueAs(
    comptime T: type,
    value: value_mod.ValueRef,
    allocator: ?std.mem.Allocator,
) Error!T {
    if (T == []u8) {
        const source = try value.asText();
        const alloc = allocator orelse return error.AllocatorRequired;
        return try alloc.dupe(u8, source);
    }
    if (T == value_mod.OwnedValue) {
        const alloc = allocator orelse return error.AllocatorRequired;
        return try value.toOwned(alloc);
    }

    return switch (@typeInfo(T)) {
        .optional => |optional| if (value.isNull())
            null
        else
            try valueAs(optional.child, value, allocator),
        else => try value.get(T),
    };
}

/// Release a value produced by `valueAs`. Borrowed/scalar values are no-ops.
pub fn deinitValue(comptime T: type, value: *T, allocator: ?std.mem.Allocator) void {
    if (T == []u8) {
        if (allocator) |alloc| alloc.free(value.*);
        return;
    }
    if (T == value_mod.OwnedValue) {
        if (allocator) |alloc| value.deinit(alloc);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| if (value.*) |*payload| {
            deinitValue(optional.child, payload, allocator);
        },
        else => {},
    }
}
