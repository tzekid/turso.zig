const std = @import("std");
const turso = @import("turso");

fn queryInt(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    const result = try row.get(i64, 0);
    try std.testing.expect((try rows.next()) == null);
    return result;
}

test "representative SQL compatibility corpus preserves relational semantics" {
    var database = try turso.Database.open(std.testing.allocator, .{
        .path = ":memory:",
        .features = .{
            .views = true,
            .generated_columns = true,
            .without_rowid = true,
        },
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("PRAGMA foreign_keys = ON", &.{}, .{});
    var diagnostics = turso.Diagnostics{};
    _ = connection.execBatch(
        \\CREATE TABLE "作者"(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL UNIQUE
        \\) STRICT;
        \\CREATE TABLE books(
        \\  id INTEGER PRIMARY KEY,
        \\  author_id INTEGER NOT NULL REFERENCES "作者"(id),
        \\  title TEXT NOT NULL,
        \\  price INTEGER NOT NULL CHECK(price >= 0),
        \\  doubled_price INTEGER GENERATED ALWAYS AS (price * 2)
        \\) STRICT;
        \\CREATE INDEX books_author_price ON books(author_id, price);
        \\CREATE VIEW priced_books AS
        \\  SELECT a.name, b.title, b.price, b.doubled_price
        \\  FROM books AS b JOIN "作者" AS a ON a.id = b.author_id;
        \\CREATE TABLE settings(
        \\  name TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\) WITHOUT ROWID;
    , .{ .diagnostics = &diagnostics }) catch |err| {
        std.debug.print("SQL corpus schema setup failed: {s}\n", .{diagnostics.text()});
        return err;
    };

    _ = try connection.exec(
        "INSERT INTO \"作者\"(id, name) VALUES (?1, ?2), (?3, ?4)",
        &.{
            .{ .integer = 1 },
            .{ .text = "Ada" },
            .{ .integer = 2 },
            .{ .text = "グレース" },
        },
        .{},
    );
    _ = try connection.exec(
        "INSERT INTO books(id, author_id, title, price) VALUES (1, 1, 'Notes', 7), (2, 2, 'Compiler', 11)",
        &.{},
        .{},
    );
    _ = try connection.exec("INSERT INTO settings VALUES ('mode', 'strict')", &.{}, .{});

    var rows = try connection.query(
        "SELECT name, title, doubled_price FROM priced_books ORDER BY price DESC",
        &.{},
        .{},
    );
    defer rows.deinit();
    const first = (try rows.next()).?;
    try std.testing.expectEqualStrings("グレース", try first.get([]const u8, 0));
    try std.testing.expectEqualStrings("Compiler", try first.get([]const u8, 1));
    try std.testing.expectEqual(@as(i64, 22), try first.get(i64, 2));
    const second = (try rows.next()).?;
    try std.testing.expectEqualStrings("Ada", try second.get([]const u8, 0));
    try std.testing.expectEqual(@as(i64, 14), try second.get(i64, 2));
    try std.testing.expect((try rows.next()) == null);
    try rows.finish(null);

    try std.testing.expectError(
        error.Constraint,
        connection.exec("INSERT INTO \"作者\" VALUES (3, 'Ada')", &.{}, .{}),
    );
    try std.testing.expectError(
        error.Constraint,
        connection.exec("INSERT INTO books(id, author_id, title, price) VALUES (3, 999, 'orphan', 1)", &.{}, .{}),
    );
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM books"));
}

test "multi-megabyte values many parameters and long prepared reuse are exact" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE bulk(id INTEGER PRIMARY KEY, payload BLOB)", &.{}, .{});

    const payload = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index *% 193);

    var transaction = try connection.begin(.immediate, .{});
    defer transaction.deinit();
    var insert = try transaction.prepare("INSERT INTO bulk VALUES (?1, ?2)", .{});
    var index: usize = 0;
    while (index < 1_000) : (index += 1) {
        try insert.bindAll(
            &.{
                .{ .integer = @intCast(index + 1) },
                .{ .blob = if (index == 999) payload else &.{} },
            },
            null,
        );
        try std.testing.expectEqual(@as(u64, 1), try insert.execute(null));
        try insert.reset(null);
    }
    insert.deinit();
    try transaction.commit(null);

    try std.testing.expectEqual(@as(i64, 1_000), try queryInt(&connection, "SELECT COUNT(*) FROM bulk"));
    var payload_rows = try connection.query("SELECT payload FROM bulk WHERE id = 1000", &.{}, .{});
    defer payload_rows.deinit();
    const payload_row = (try payload_rows.next()).?;
    try std.testing.expectEqualSlices(u8, payload, (try payload_row.get(turso.Blob, 0)).bytes);
    try payload_rows.finish(null);

    const parameters = [_]turso.Value{
        .{ .integer = 1 },  .{ .integer = 2 },  .{ .integer = 3 },  .{ .integer = 4 },
        .{ .integer = 5 },  .{ .integer = 6 },  .{ .integer = 7 },  .{ .integer = 8 },
        .{ .integer = 9 },  .{ .integer = 10 }, .{ .integer = 11 }, .{ .integer = 12 },
        .{ .integer = 13 }, .{ .integer = 14 }, .{ .integer = 15 }, .{ .integer = 16 },
        .{ .integer = 17 }, .{ .integer = 18 }, .{ .integer = 19 }, .{ .integer = 20 },
        .{ .integer = 21 }, .{ .integer = 22 }, .{ .integer = 23 }, .{ .integer = 24 },
        .{ .integer = 25 }, .{ .integer = 26 }, .{ .integer = 27 }, .{ .integer = 28 },
        .{ .integer = 29 }, .{ .integer = 30 }, .{ .integer = 31 }, .{ .integer = 32 },
    };
    var sum_rows = try connection.query(
        "SELECT ?1+?2+?3+?4+?5+?6+?7+?8+?9+?10+?11+?12+?13+?14+?15+?16+" ++
            "?17+?18+?19+?20+?21+?22+?23+?24+?25+?26+?27+?28+?29+?30+?31+?32",
        &parameters,
        .{},
    );
    defer sum_rows.deinit();
    try std.testing.expectEqual(@as(i64, 528), try (try sum_rows.next()).?.get(i64, 0));
    try sum_rows.finish(null);
}
