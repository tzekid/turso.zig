const std = @import("std");
const turso = @import("turso");

extern fn turso_zig_database_set_mode(mode: c_int) void;
extern fn turso_zig_database_reset_counts() void;
extern fn turso_zig_database_created() usize;
extern fn turso_zig_database_deinited() usize;
extern fn turso_zig_database_error_deinited() usize;

test "database constructor failure releases returned error and partial handle once" {
    turso_zig_database_reset_counts();
    turso_zig_database_set_mode(1);
    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.TursoFailure,
        turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings("database new failed", diagnostics.text());
    try expectBalanced(1);
}

test "database open failure releases returned error and constructed handle once" {
    turso_zig_database_reset_counts();
    turso_zig_database_set_mode(2);
    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.TursoFailure,
        turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings("database open failed", diagnostics.text());
    try expectBalanced(1);
}

test "every Zig allocation failure after native construction releases the handle" {
    turso_zig_database_reset_counts();
    turso_zig_database_set_mode(0);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, openAndClose, .{});
    try std.testing.expect(turso_zig_database_created() != 0);
    try expectBalanced(0);
}

fn openAndClose(allocator: std.mem.Allocator) !void {
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    defer database.deinit();
}

fn expectBalanced(expected_error_deinits: usize) !void {
    try std.testing.expectEqual(turso_zig_database_created(), turso_zig_database_deinited());
    try std.testing.expectEqual(expected_error_deinits, turso_zig_database_error_deinited());
}
