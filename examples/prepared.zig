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

    var select = try connection.prepare(
        "SELECT id, name FROM people WHERE id >= :minimum ORDER BY id",
        .{},
    );
    defer select.deinit();
    for ([_]i64{ 1, 3 }) |minimum| {
        var rows = try select.queryParams(.{ .minimum = minimum }, null);
        defer rows.deinit();
        while (try rows.next()) |row| {
            std.debug.print("from {d}: {d}: {s}\n", .{
                minimum,
                try row.get(i64, 0),
                try row.get([]const u8, 1),
            });
        }
        // finish drains and resets this execution, returning `select` to ready.
        try rows.finish(null);
    }

    // Early iteration is an explicit cancellation decision. This prevents
    // deinit from silently being treated as successful completion and also
    // returns the prepared statement to ready.
    var preview = try select.queryParams(.{ .minimum = @as(i64, 1) }, null);
    defer preview.deinit();
    if (try preview.next()) |row| {
        std.debug.print("preview: {s}\n", .{try row.get([]const u8, 1)});
    }
    try preview.cancel(null);
}
