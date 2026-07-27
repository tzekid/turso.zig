const std = @import("std");
const turso = @import("turso");

fn queryCount(connection: *turso.Connection, table: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(std.testing.allocator, "SELECT COUNT(*) FROM {s}", .{table});
    defer std.testing.allocator.free(sql);
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    return (try rows.next()).?.get(i64, 0);
}

fn queryInteger(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const value = try (try rows.next()).?.get(i64, 0);
    try std.testing.expect((try rows.next()) == null);
    return value;
}

test "stable native constraint and generic failures retain diagnostics" {
    var diagnostics = turso.Diagnostics{};
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE unique_values(value INTEGER UNIQUE)", &.{}, .{});
    _ = try connection.exec("INSERT INTO unique_values VALUES (1)", &.{}, .{});
    try std.testing.expectError(
        error.Constraint,
        connection.exec("INSERT INTO unique_values VALUES (1)", &.{}, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqual(turso.Status.constraint, diagnostics.status);
    try std.testing.expect(diagnostics.text().len != 0);

    try std.testing.expectError(
        error.TursoFailure,
        connection.prepare("SELECT FROM", .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqual(turso.Status.failure, diagnostics.status);
    try std.testing.expect(diagnostics.text().len != 0);
}

test "complete batch validation happens before its first side effect" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE batch_guard(value INTEGER)", &.{}, .{});

    try std.testing.expectError(
        error.InteriorNul,
        connection.execBatch(
            "INSERT INTO batch_guard VALUES (1);\x00INSERT INTO batch_guard VALUES (2)",
            .{},
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&connection, "batch_guard"));

    const invalid_utf8 = [_]u8{
        'I', 'N', 'S', 'E', 'R', 'T', ' ', 'I', 'N', 'T', 'O', ' ',
        'b', 'a', 't', 'c', 'h', '_', 'g', 'u', 'a', 'r', 'd', ' ',
        'V', 'A', 'L', 'U', 'E', 'S', ' ', '(', '3', ')', ';', 0xff,
    };
    try std.testing.expectError(error.InvalidUtf8, connection.execBatch(&invalid_utf8, .{}));
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&connection, "batch_guard"));
}

test "max page count reports DatabaseFull without a partial row" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE bounded(payload BLOB NOT NULL)", &.{}, .{});

    const page_count = try queryInteger(&connection, "PRAGMA page_count");
    const pragma = try std.fmt.allocPrint(std.testing.allocator, "PRAGMA max_page_count = {d}", .{page_count});
    defer std.testing.allocator.free(pragma);
    _ = try connection.exec(pragma, &.{}, .{});

    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xa5);
    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.DatabaseFull,
        connection.exec(
            "INSERT INTO bounded VALUES (?1)",
            &.{.{ .blob = payload }},
            .{ .diagnostics = &diagnostics },
        ),
    );
    try std.testing.expectEqual(turso.Status.database_full, diagnostics.status);
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&connection, "bounded"));
}

test "wrapper rejects invalid extension inputs before native use" {
    var diagnostics = turso.Diagnostics{};
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try std.testing.expectError(
        error.InvalidState,
        connection.loadExtension("", &diagnostics),
    );
    try std.testing.expect(diagnostics.text().len != 0);
    try std.testing.expectError(
        error.InteriorNul,
        connection.loadExtension("safe-prefix\x00ignored", &diagnostics),
    );
    const invalid_path = [_]u8{ 'x', 0xff };
    try std.testing.expectError(
        error.InvalidUtf8,
        connection.loadExtension(&invalid_path, &diagnostics),
    );
}

const RetainedCounters = struct { drops: usize = 0 };
const RetainedContext = struct {
    multiplier: i64,
    counters: *RetainedCounters,
};

fn retainedMultiply(
    context: *RetainedContext,
    args: []const turso.Value,
) turso.Connection.CallbackError!turso.Value {
    if (args.len != 1) return error.InvalidArguments;
    const value = args[0].asInteger() catch return error.InvalidArguments;
    return .{ .integer = std.math.mul(i64, value, context.multiplier) catch return error.OutOfRange };
}

fn dropRetained(context: *RetainedContext) void {
    context.counters.drops += 1;
}

test "function replacement releases old context after exclusive statement ownership ends" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var counters = RetainedCounters{};

    try connection.registerScalarFunction(
        "retained_multiply",
        turso.Connection.ScalarFunctionOptions(RetainedContext){
            .context = .{ .multiplier = 2, .counters = &counters },
            .callback = retainedMultiply,
            .context_deinit = dropRetained,
            .argc = 1,
        },
        null,
    );
    var old_statement = try connection.prepare("SELECT retained_multiply(3)", .{});

    // The connection is exclusive while a Statement is alive, so replacement
    // occurs only after releasing it. This test intentionally does not claim
    // that registration can overlap statement ownership.
    old_statement.deinit();
    try connection.registerScalarFunction(
        "retained_multiply",
        turso.Connection.ScalarFunctionOptions(RetainedContext){
            .context = .{ .multiplier = 3, .counters = &counters },
            .callback = retainedMultiply,
            .context_deinit = dropRetained,
            .argc = 1,
        },
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), counters.drops);
    try connection.unregisterFunction("retained_multiply", null);
    try std.testing.expectEqual(@as(usize, 2), counters.drops);
}
