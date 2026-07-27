const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var database = try turso.Database.open(arena.allocator(), .{ .path = ":memory:" });
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.exec(
        "INSERT INTO users(name) VALUES (?1)",
        &.{.{ .text = "Ada" }},
        .{},
    );

    var rows = try connection.query("SELECT id, name FROM users", &.{}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        std.debug.print("user {d}: {s}\n", .{
            try row.get(i64, 0),
            try row.get([]const u8, 1),
        });
    }
}
