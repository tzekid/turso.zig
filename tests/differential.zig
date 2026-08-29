const std = @import("std");
const turso = @import("turso");
const raw = turso.raw.c;

test "raw and safe layers agree on statuses and all SQL value kinds" {
    var raw_error: [*c]const u8 = null;
    const raw_config = raw.turso_database_config_t{
        .async_io = 0,
        .path = ":memory:",
        .experimental_features = null,
        .vfs = null,
        .encryption_cipher = null,
        .encryption_hexkey = null,
        .page_codec = null,
        .open_flags = raw.TURSO_DATABASE_OPEN_DEFAULT,
    };
    var raw_database: ?*const raw.turso_database_t = null;
    try expectRaw(raw.TURSO_OK, raw.turso_database_new(&raw_config, &raw_database, &raw_error), &raw_error);
    defer raw.turso_database_deinit(raw_database);
    try expectRaw(raw.TURSO_OK, raw.turso_database_open(raw_database, &raw_error), &raw_error);
    var raw_connection: ?*raw.turso_connection_t = null;
    try expectRaw(raw.TURSO_OK, raw.turso_database_connect(raw_database, &raw_connection, &raw_error), &raw_error);
    defer raw.turso_connection_deinit(raw_connection);
    var raw_statement: ?*raw.turso_statement_t = null;
    try expectRaw(
        raw.TURSO_OK,
        raw.turso_connection_prepare_single(
            raw_connection,
            "SELECT NULL, -7, 1.25, 'hello', X'00FF'",
            &raw_statement,
            &raw_error,
        ),
        &raw_error,
    );
    defer raw.turso_statement_deinit(raw_statement);

    const row_status = raw.turso_statement_step(raw_statement, &raw_error);
    try expectRaw(raw.TURSO_ROW, row_status, &raw_error);
    try std.testing.expectEqual(turso.Status.row, try turso.Status.fromRaw(row_status));

    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var rows = try connection.query(
        "SELECT NULL, -7, 1.25, 'hello', X'00FF'",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;

    try std.testing.expectEqual(@as(raw.turso_type_t, raw.TURSO_TYPE_NULL), raw.turso_statement_row_value_kind(raw_statement, 0));
    try std.testing.expect((try row.value(0)).isNull());
    try std.testing.expectEqual(raw.turso_statement_row_value_int(raw_statement, 1), try row.get(i64, 1));
    try std.testing.expectEqual(raw.turso_statement_row_value_double(raw_statement, 2), try row.get(f64, 2));
    try expectRawBytes(raw_statement.?, 3, try row.get([]const u8, 3));
    try expectRawBytes(raw_statement.?, 4, (try row.get(turso.Blob, 4)).bytes);

    try std.testing.expect((try rows.next()) == null);
    const done_status = raw.turso_statement_step(raw_statement, &raw_error);
    try expectRaw(raw.TURSO_DONE, done_status, &raw_error);
    try std.testing.expectEqual(turso.Status.done, try turso.Status.fromRaw(done_status));
}

test "owned metadata outlives the native statement" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec(
        "CREATE TABLE metadata_source(id INTEGER PRIMARY KEY, name TEXT)",
        &.{},
        .{},
    );

    var statement = try connection.prepare(
        "SELECT id AS identifier, name FROM metadata_source WHERE id = :id",
        .{},
    );
    var parameter = try statement.parameterInfo(std.testing.allocator, 1);
    defer parameter.deinit(std.testing.allocator);
    var id_column = try statement.columnInfo(std.testing.allocator, 0);
    defer id_column.deinit(std.testing.allocator);
    var name_column = try statement.columnInfo(std.testing.allocator, 1);
    defer name_column.deinit(std.testing.allocator);

    statement.deinit();
    try std.testing.expectEqualStrings(":id", parameter.name.?);
    try std.testing.expectEqualStrings("identifier", id_column.name);
    try std.testing.expectEqualStrings("INTEGER", id_column.declared_type.?);
    try std.testing.expectEqualStrings("name", name_column.name);
    try std.testing.expectEqualStrings("TEXT", name_column.declared_type.?);

    // Public owned-value cleanup follows the package-wide idempotent deinit
    // contract even after the native statement has gone away.
    id_column.deinit(std.testing.allocator);
    name_column.deinit(std.testing.allocator);
}

fn expectRaw(
    expected: raw.turso_status_code_t,
    actual: raw.turso_status_code_t,
    error_message: *[*c]const u8,
) !void {
    defer {
        if (error_message.* != null) raw.turso_str_deinit(error_message.*);
        error_message.* = null;
    }
    if (actual != expected) return error.UnexpectedRawStatus;
}

fn expectRawBytes(
    statement: *raw.turso_statement_t,
    index: usize,
    expected: []const u8,
) !void {
    const native_len = raw.turso_statement_row_value_bytes_count(statement, index);
    try std.testing.expect(native_len >= 0);
    const len: usize = @intCast(native_len);
    if (len == 0) return std.testing.expectEqual(@as(usize, 0), expected.len);
    const native_ptr = raw.turso_statement_row_value_bytes_ptr(statement, index);
    try std.testing.expect(native_ptr != null);
    const bytes: [*]const u8 = @ptrCast(native_ptr);
    try std.testing.expectEqualSlices(u8, bytes[0..len], expected);
}
