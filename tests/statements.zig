const std = @import("std");
const database_mod = @import("turso");

const Blob = database_mod.Blob;
const Value = database_mod.Value;

test "blocking CRUD round trips every SQL value kind" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE values_test(n, i INTEGER, r REAL, t TEXT, b BLOB)",
        &.{},
        .{},
    );

    var insert = try connection.prepare(
        "INSERT INTO values_test VALUES (?1, ?2, ?3, ?4, ?5)",
        .{},
    );
    defer insert.deinit();
    const text = "hello\x00zig";
    const blob_bytes = [_]u8{ 0x00, 0xff, 0x7f, 0x80 };
    const values = [_]Value{
        .null_value,
        .{ .integer = 42 },
        .{ .real = 3.5 },
        .{ .text = text },
        .{ .blob = &blob_bytes },
    };
    try insert.bindAll(&values, null);
    try std.testing.expectEqual(@as(u64, 1), try insert.execute(null));
    try insert.reset(null);
    try insert.finalize(null);
    try std.testing.expectError(error.InvalidState, insert.reset(null));
    insert.deinit();

    var rows = try connection.query("SELECT n, i, r, t, b FROM values_test", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(usize, 5), row.columnCount());
    try std.testing.expect((try row.value(0)).isNull());
    try std.testing.expectEqual(@as(i64, 42), try row.get(i64, 1));
    try std.testing.expectEqual(@as(f64, 3.5), try row.get(f64, 2));
    try std.testing.expectEqualStrings(text, try row.get([]const u8, 3));
    try std.testing.expectEqualSlices(u8, &blob_bytes, (try row.get(Blob, 4)).bytes);
    try std.testing.expectError(error.ColumnOutOfBounds, row.value(5));
    try std.testing.expect((try rows.next()) == null);
}

test "statement state and one-based bindings are enforced" {
    var diagnostics = database_mod.Diagnostics{};
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var statement = try connection.prepare("SELECT ?1", .{});
    defer statement.deinit();
    try std.testing.expectError(error.ParameterNotFound, statement.bind(0, .{ .integer = 1 }, &diagnostics));
    try std.testing.expect(diagnostics.text().len != 0);
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, statement.bind(1, .{ .text = &invalid_utf8 }, &diagnostics));
    try statement.bind(1, .{ .integer = 1 }, &diagnostics);
    try std.testing.expectError(error.InvalidState, connection.prepare("SELECT 2", .{ .diagnostics = &diagnostics }));
    try std.testing.expectError(error.InvalidState, connection.isAutocommit());
    try std.testing.expectError(error.InvalidState, connection.lastInsertRowId());

    var rows = try statement.intoRows(null);
    defer rows.deinit();
    try std.testing.expectError(error.InvalidState, connection.isAutocommit());
    try std.testing.expectError(error.InvalidState, connection.lastInsertRowId());
    try std.testing.expect((try rows.next()) != null);
    try std.testing.expect((try rows.next()) == null);
    try std.testing.expect((try rows.next()) == null);
}

test "empty Unicode and large length-delimited values round trip exactly" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE payloads(t TEXT, empty_t TEXT, b BLOB, empty_b BLOB)", &.{}, .{});
    const text = "Turso — こんにちは — \x00 — Zig";
    const large_blob = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(large_blob);
    for (large_blob, 0..) |*byte, index| byte.* = @truncate(index *% 131);
    const empty = [_]u8{};
    _ = try connection.exec(
        "INSERT INTO payloads VALUES (?1, ?2, ?3, ?4)",
        &.{
            .{ .text = text },
            .{ .text = "" },
            .{ .blob = large_blob },
            .{ .blob = &empty },
        },
        .{},
    );
    try std.testing.expect((try connection.lastInsertRowId()) > 0);

    var rows = try connection.query("SELECT t, empty_t, b, empty_b FROM payloads", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqualStrings(text, try row.get([]const u8, 0));
    try std.testing.expectEqualStrings("", try row.get([]const u8, 1));
    try std.testing.expectEqualSlices(u8, large_blob, (try row.get(Blob, 2)).bytes);
    try std.testing.expectEqual(@as(usize, 0), (try row.get(Blob, 3)).bytes.len);
}

test "integer extrema real edges and bound bytes are copied immediately" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE edge_values(lo INTEGER, hi INTEGER, negzero REAL, finite REAL, text_value TEXT, blob_value BLOB)", &.{}, .{});

    var text = [_]u8{ 'c', 'o', 'p', 'i', 'e', 'd' };
    var blob = [_]u8{ 0x00, 0x7f, 0x80, 0xff };
    var insert = try connection.prepare("INSERT INTO edge_values VALUES (?1, ?2, ?3, ?4, ?5, ?6)", .{});
    try insert.bindAll(
        &.{
            .{ .integer = std.math.minInt(i64) },
            .{ .integer = std.math.maxInt(i64) },
            .{ .real = -0.0 },
            .{ .real = std.math.floatMax(f64) },
            .{ .text = &text },
            .{ .blob = &blob },
        },
        null,
    );
    @memset(&text, 'x');
    @memset(&blob, 0x55);
    _ = try insert.execute(null);
    insert.deinit();

    var rows = try connection.query("SELECT * FROM edge_values", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(std.math.minInt(i64), try row.get(i64, 0));
    try std.testing.expectEqual(std.math.maxInt(i64), try row.get(i64, 1));
    try std.testing.expect(std.math.signbit(try row.get(f64, 2)));
    try std.testing.expectEqual(std.math.floatMax(f64), try row.get(f64, 3));
    try std.testing.expectEqualStrings("copied", try row.get([]const u8, 4));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7f, 0x80, 0xff }, (try row.get(Blob, 5)).bytes);
    try rows.finish(null);
}

test "every SQL parameter spelling preserves one-based and sparse indexing" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var sparse = try connection.prepare("SELECT ?, ?5", .{});
    defer sparse.deinit();
    try std.testing.expectEqual(@as(usize, 5), try sparse.parameterCount());
    const first_name = (try sparse.parameterName(std.testing.allocator, 1)).?;
    defer std.testing.allocator.free(first_name);
    try std.testing.expectEqualStrings("?1", first_name);
    const fifth_name = (try sparse.parameterName(std.testing.allocator, 5)).?;
    defer std.testing.allocator.free(fifth_name);
    try std.testing.expectEqualStrings("?5", fifth_name);
    try std.testing.expectError(error.ParameterNotFound, sparse.parameterName(std.testing.allocator, 0));
    try std.testing.expectError(error.ParameterNotFound, sparse.bind(6, .{ .integer = 1 }, null));
    try sparse.bind(1, .{ .integer = 11 }, null);
    try sparse.bindNamed("?5", @as(i64, 55), null);
    var sparse_rows = try sparse.intoRows(null);
    defer sparse_rows.deinit();
    const sparse_row = (try sparse_rows.next()).?;
    try std.testing.expectEqual(@as(i64, 11), try sparse_row.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 55), try sparse_row.get(i64, 1));
    try sparse_rows.finish(null);

    var named = try connection.prepare("SELECT :x, @y, $z, :x", .{});
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 3), try named.parameterCount());
    try named.bindNamed(":x", @as(i64, 1), null);
    try named.bindNamed("@y", @as(i64, 2), null);
    try named.bindNamed("$z", @as(i64, 3), null);
    var named_rows = try named.intoRows(null);
    defer named_rows.deinit();
    const named_row = (try named_rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try named_row.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 2), try named_row.get(i64, 1));
    try std.testing.expectEqual(@as(i64, 3), try named_row.get(i64, 2));
    try std.testing.expectEqual(@as(i64, 1), try named_row.get(i64, 3));
}

test "reset clears bindings and finalize is idempotent from all safe terminal paths" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE reset_values(value INTEGER UNIQUE)", &.{}, .{});

    var insert = try connection.prepare("INSERT INTO reset_values VALUES (?1)", .{});
    try insert.bind(1, .{ .integer = 7 }, null);
    _ = try insert.execute(null);
    try insert.reset(null);
    _ = try insert.execute(null);
    try insert.finalize(null);
    try insert.finalize(null);
    insert.deinit();

    var rows = try connection.query(
        "SELECT value IS NULL FROM reset_values ORDER BY rowid",
        &.{},
        .{},
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 1), try (try rows.next()).?.get(i64, 0));
    try rows.finish(null);

    var failed = try connection.prepare("INSERT INTO reset_values VALUES (7)", .{});
    try std.testing.expectError(error.Constraint, failed.execute(null));
    try failed.finalize(null);
    try failed.finalize(null);
    failed.deinit();

    var ready = try connection.prepare("SELECT 1", .{});
    try ready.finalize(null);
    try ready.finalize(null);
    ready.deinit();
}

test "getter and metadata sentinels reject wrong kinds stale rows and terminal handles" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE metadata_values(id INTEGER, name TEXT)", &.{}, .{});

    var statement = try connection.prepare("SELECT id, name, id + 1 AS successor FROM metadata_values", .{});
    var id_info = try statement.columnInfo(std.testing.allocator, 0);
    defer id_info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("id", id_info.name);
    try std.testing.expect(id_info.declared_type != null);
    var expression_info = try statement.columnInfo(std.testing.allocator, 2);
    defer expression_info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("successor", expression_info.name);
    try std.testing.expectError(error.ColumnOutOfBounds, statement.columnInfo(std.testing.allocator, 3));
    try statement.finalize(null);
    try std.testing.expectError(error.InvalidState, statement.columnCount());
    try std.testing.expectError(error.InvalidState, statement.parameterCount());
    try std.testing.expectError(error.InvalidState, statement.columnInfo(std.testing.allocator, 0));
    statement.deinit();

    var live_rows = try connection.query("SELECT 42, 'text'", &.{}, .{});
    defer live_rows.deinit();
    const row = (try live_rows.next()).?;
    try std.testing.expectError(error.TypeMismatch, row.get([]const u8, 0));
    try std.testing.expectError(error.TypeMismatch, row.get(i64, 1));
    try std.testing.expectError(error.ColumnOutOfBounds, row.value(2));
    try live_rows.finish(null);
    try std.testing.expectError(error.InvalidState, row.value(0));
}
