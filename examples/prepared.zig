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
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );

    const people = [_]struct { id: i64, name: []const u8 }{
        .{ .id = 1, .name = "Ada" },
        .{ .id = 2, .name = "Grace" },
        .{ .id = 3, .name = "Linus" },
    };
    var insert = try connection.prepare(
        "INSERT INTO people(id, name) VALUES (?1, ?2)",
        .{},
    );
    defer insert.deinit();
    for (people, 0..) |person, index| {
        // Tuple conversion and positional binding allocate no Zig memory.
        try insert.bindParams(.{ person.id, person.name }, null);
        _ = try insert.execute(null);
        if (index + 1 != people.len) try insert.reset(null);
    }
    // finish reports terminal native errors; deinit still releases the outer
    // native handle and is idempotent after manual cleanup.
    try insert.finish(null);
    insert.deinit();

    var rows = try connection.query(
        "SELECT id, name FROM people ORDER BY id",
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
    try rows.finish(null);

    // Early iteration is an explicit cancellation decision. This prevents
    // deinit from silently being treated as successful completion.
    var preview = try connection.query(
        "SELECT name FROM people ORDER BY id",
        &.{},
        .{},
    );
    defer preview.deinit();
    if (try preview.next()) |row| {
        std.debug.print("preview: {s}\n", .{try row.get([]const u8, 0)});
    }
    try preview.cancel(null);
}
