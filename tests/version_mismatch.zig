const std = @import("std");
const turso = @import("turso");

extern var turso_zig_mismatch_database_new_calls: c_int;

test "incompatible runtime is rejected before database configuration crosses C" {
    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.VersionMismatch,
        turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqual(@as(c_int, 0), turso_zig_mismatch_database_new_calls);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "does not match") != null);
}
