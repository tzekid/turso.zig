const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{ InteriorNul, InvalidUtf8 };

pub fn validate(bytes: []const u8) error{ InteriorNul, InvalidUtf8 }!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        return error.InteriorNul;
    }
}

pub fn dupe(allocator: std.mem.Allocator, bytes: []const u8) Error![:0]u8 {
    try validate(bytes);
    return allocator.dupeSentinel(u8, bytes, 0);
}

test "dupe creates an owned C string" {
    const value = try dupe(std.testing.allocator, "turso");
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("turso", value);
    try std.testing.expectEqual(@as(u8, 0), value.ptr[value.len]);
}

test "dupe rejects interior NUL" {
    try std.testing.expectError(
        error.InteriorNul,
        dupe(std.testing.allocator, "tur\x00so"),
    );
}

test "dupe rejects invalid UTF-8 before crossing the C boundary" {
    const invalid = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, dupe(std.testing.allocator, &invalid));
}
