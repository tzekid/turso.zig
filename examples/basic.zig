const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var database = try turso.Database.open(
        std.heap.page_allocator,
        .{ .path = ":memory:" },
    );
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.execParams(
        "INSERT INTO users(name) VALUES (?1)",
        .{"Ada"},
        .{},
    );

    var rows = try connection.query(
        "SELECT id, name FROM users",
        &.{},
        .{},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        std.debug.print("{d}: {s}\n", .{
            try row.get(i64, 0),
            try row.get([]const u8, 1),
        });
    }
}
