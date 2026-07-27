const std = @import("std");
const turso = @import("turso");

pub fn main(init: std.process.Init) !void {
    var database = try turso.Database.open(init.gpa, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.execParams(
        "INSERT INTO people(id, name) VALUES (:id, :name)",
        .{ .id = @as(i64, 1), .name = "Ada" },
        .{},
    );

    const Person = struct {
        id: i64,
        name: []const u8,
    };
    var rows = try connection.queryParams(
        "SELECT id, name FROM people WHERE id = ?1",
        .{@as(i64, 1)},
        .{},
    );
    defer rows.deinit();
    while (try rows.nextAs(Person, null, .{ .mode = .by_name })) |person| {
        // Borrowed text remains valid only until the next Rows operation.
        std.debug.print("person {d}: {s}\n", .{ person.id, person.name });
    }
    try rows.finish(null);

    // Extension loading starts disabled. Enabling it should be a narrow,
    // deliberate scope around a trusted extension path.
    try connection.enableLoadExtension(true, null);
    defer connection.enableLoadExtension(false, null) catch {};
    try connection.enableLoadExtension(false, null);
}
