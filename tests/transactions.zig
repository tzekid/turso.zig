const std = @import("std");
const turso = @import("turso");

fn queryInt(owner: anytype, sql: []const u8) !i64 {
    var rows = try owner.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    const value = try row.get(i64, 0);
    try std.testing.expect((try rows.next()) == null);
    return value;
}

test "execBatch advances tail offsets and validates the complete input first" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try std.testing.expectEqual(@as(u64, 2), try connection.execBatch(
        \\ -- leading SQL trivia
        \\ CREATE TABLE batch_items(value INTEGER);
        \\ INSERT INTO batch_items VALUES (1);
        \\ /* a semicolon in a comment ; */ INSERT INTO batch_items VALUES (2);
        \\ -- trailing trivia
    , .{}));
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM batch_items"));
    try std.testing.expectEqual(@as(u64, 0), try connection.execBatch(" ; -- nothing executable", .{}));

    try std.testing.expectError(
        error.InteriorNul,
        connection.execBatch("INSERT INTO batch_items VALUES (3);\x00INSERT INTO batch_items VALUES (4)", .{}),
    );
    const invalid_utf8 = [_]u8{ 'I', 'N', 'S', 'E', 'R', 'T', 0xff };
    try std.testing.expectError(error.InvalidUtf8, connection.execBatch(&invalid_utf8, .{}));
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM batch_items"));
}

test "transactions commit roll back and roll back on deinit" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE tx_items(value INTEGER)", &.{}, .{});

    var committed = try connection.begin(.deferred, .{});
    defer committed.deinit();
    try std.testing.expect(!(try committed.isAutocommit()));
    _ = try committed.exec("INSERT INTO tx_items VALUES (1)", &.{}, .{});
    try committed.commit(null);
    try std.testing.expectEqual(.committed, committed.state);
    try std.testing.expect(try connection.isAutocommit());

    var rolled_back = try connection.begin(.immediate, .{});
    defer rolled_back.deinit();
    _ = try rolled_back.exec("INSERT INTO tx_items VALUES (2)", &.{}, .{});
    try rolled_back.rollback(null);
    try std.testing.expectEqual(.rolled_back, rolled_back.state);

    var implicit = try connection.begin(.exclusive, .{});
    _ = try implicit.exec("INSERT INTO tx_items VALUES (3)", &.{}, .{});
    implicit.deinit();
    try std.testing.expectEqual(.rolled_back, implicit.state);

    // The API exposes Turso's concurrent mode without retrying BusySnapshot;
    // production callers must enable the documented MVCC precondition.
    _ = try connection.exec("PRAGMA journal_mode = 'mvcc'", &.{}, .{});
    var concurrent = try connection.begin(.concurrent, .{});
    defer concurrent.deinit();
    try concurrent.rollback(null);

    try std.testing.expectEqual(@as(i64, 1), try queryInt(&connection, "SELECT COUNT(*) FROM tx_items"));
}

test "transaction typed one-shot helpers preserve active ownership after bind failure" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE typed_tx(id INTEGER, name TEXT)", &.{}, .{});

    var transaction = try connection.begin(.deferred, .{});
    defer transaction.deinit();
    try std.testing.expectEqual(
        @as(u64, 1),
        try transaction.execParams(
            "INSERT INTO typed_tx VALUES (?1, ?2)",
            .{ @as(i64, 1), "Ada" },
            .{},
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        try transaction.execParams(
            "INSERT INTO typed_tx VALUES (:id, :name)",
            .{ .name = "Grace", .id = @as(i64, 2) },
            .{},
        ),
    );

    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.UnusedField,
        transaction.queryParams(
            "SELECT name FROM typed_tx WHERE id = :id",
            .{ .id = @as(i64, 1), .extra = @as(i64, 2) },
            .{ .diagnostics = &diagnostics },
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "unused") != null);

    // Failed binding releases the one prepared statement without ending or
    // poisoning the transaction.
    var rows = try transaction.queryParams(
        "SELECT name FROM typed_tx WHERE id = :id",
        .{ .id = @as(i64, 2) },
        .{ .diagnostics = &diagnostics },
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expectEqualStrings("Grace", try (try rows.next()).?.get([]const u8, 0));
    try rows.finish(null);
    rows.deinit();

    try transaction.commit(null);
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM typed_tx"));
}

test "transaction exclusively borrows stable connection state" {
    var diagnostics = turso.Diagnostics{};
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});

    var transaction = try connection.begin(.deferred, .{});
    defer transaction.deinit();
    try std.testing.expectError(error.InvalidState, connection.exec("SELECT 1", &.{}, .{ .diagnostics = &diagnostics }));
    try std.testing.expectError(error.InvalidState, connection.begin(.deferred, .{ .diagnostics = &diagnostics }));

    // Moving the Connection value does not move the control block borrowed by
    // the transaction or by statements created from it.
    var moved = connection;
    defer moved.deinit();
    connection = undefined;
    var statement = try transaction.prepare("SELECT 1", .{});
    try std.testing.expectError(error.InvalidState, transaction.commit(&diagnostics));
    statement.deinit();
    try transaction.rollback(&diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expect(try moved.isAutocommit());
}

test "batch failure is atomic when explicitly wrapped in a transaction" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE unique_items(value INTEGER UNIQUE)", &.{}, .{});

    var transaction = try connection.begin(.deferred, .{});
    defer transaction.deinit();
    try std.testing.expectError(error.Constraint, transaction.execBatch(
        "INSERT INTO unique_items VALUES (1); INSERT INTO unique_items VALUES (1);",
        .{},
    ));
    // A statement failure preserves wrapper transaction ownership so cleanup
    // remains possible and observable.
    try transaction.finish(null);
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM unique_items"));
}

test "busy timeout preserves Busy as a caller-visible transaction outcome" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/busy.db", .{absolute_buffer[0..absolute_len]});
    defer std.testing.allocator.free(path);

    var database_a = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer database_a.deinit();
    var database_b = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer database_b.deinit();
    var connection_a = try database_a.connect(.{});
    defer connection_a.deinit();
    var connection_b = try database_b.connect(.{});
    defer connection_b.deinit();
    try connection_b.setBusyTimeout(0, null);
    try std.testing.expectError(
        error.IntegerOverflow,
        connection_b.setBusyTimeout(@as(u64, std.math.maxInt(i64)) + 1, null),
    );
    _ = try connection_a.exec("CREATE TABLE busy_items(value INTEGER)", &.{}, .{});

    var writer = try connection_a.begin(.immediate, .{});
    defer writer.deinit();
    _ = try writer.exec("INSERT INTO busy_items VALUES (1)", &.{}, .{});
    try std.testing.expectError(error.Busy, connection_b.begin(.immediate, .{}));
    try writer.rollback(null);

    var next_writer = try connection_b.begin(.immediate, .{});
    defer next_writer.deinit();
    try next_writer.rollback(null);
}

test "deinit aborts a failed BEGIN before finalization can acquire the released lock" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/failed-begin.db", .{absolute_buffer[0..absolute_len]});
    defer std.testing.allocator.free(path);

    var holder_database = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer holder_database.deinit();
    var contender_database = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer contender_database.deinit();
    var holder_connection = try holder_database.connect(.{});
    defer holder_connection.deinit();
    var contender_connection = try contender_database.connect(.{ .busy_timeout_ms = 0 });
    defer contender_connection.deinit();

    var holder = try holder_connection.begin(.immediate, .{});
    defer holder.deinit();
    var failed_begin = try contender_connection.prepare("BEGIN IMMEDIATE", .{});
    defer failed_begin.deinit();
    try std.testing.expectError(error.Busy, failed_begin.execute(null));

    try holder.rollback(null);
    failed_begin.deinit();
    try std.testing.expect(try contender_connection.isAutocommit());

    var recovered = try contender_connection.begin(.immediate, .{});
    defer recovered.deinit();
    try recovered.rollback(null);
}

test "stale deferred read snapshot reports BusySnapshot and recovers after rollback" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/busy-snapshot.db", .{absolute_buffer[0..absolute_len]});
    defer std.testing.allocator.free(path);

    var database_a = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer database_a.deinit();
    var database_b = try turso.Database.open(std.testing.allocator, .{ .path = path });
    defer database_b.deinit();
    var connection_a = try database_a.connect(.{});
    defer connection_a.deinit();
    var connection_b = try database_b.connect(.{});
    defer connection_b.deinit();
    _ = try connection_a.exec("CREATE TABLE snapshots(value INTEGER)", &.{}, .{});

    var first = try connection_a.begin(.deferred, .{});
    defer first.deinit();
    var stale = try connection_b.begin(.deferred, .{});
    defer stale.deinit();
    {
        var rows = try stale.query("SELECT COUNT(*) FROM snapshots", &.{}, .{});
        defer rows.deinit();
        try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
        try rows.finish(null);
    }
    _ = try first.exec("INSERT INTO snapshots VALUES (1)", &.{}, .{});
    try first.commit(null);

    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.BusySnapshot,
        stale.exec("INSERT INTO snapshots VALUES (2)", &.{}, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqual(turso.Status.busy_snapshot, diagnostics.status);
    try stale.rollback(null);

    var recovered = try connection_b.begin(.deferred, .{});
    defer recovered.deinit();
    _ = try recovered.exec("INSERT INTO snapshots VALUES (2)", &.{}, .{});
    try recovered.commit(null);
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection_b, "SELECT COUNT(*) FROM snapshots"));
}

test "generic SQL cannot escape wrapper-owned transaction state" {
    {
        var diagnostics = turso.Diagnostics{};
        var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();

        try std.testing.expectError(
            error.InvalidState,
            connection.exec("BEGIN", &.{}, .{ .diagnostics = &diagnostics }),
        );
        try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "transaction state") != null);
        try std.testing.expectError(error.InvalidState, connection.exec("SELECT 1", &.{}, .{}));
    }

    {
        var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        var statement = try connection.prepare("SAVEPOINT escaped", .{});
        defer statement.deinit();
        try std.testing.expectError(error.InvalidState, statement.execute(null));
    }

    {
        var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        var transaction = try connection.begin(.deferred, .{});
        defer transaction.deinit();

        try std.testing.expectError(
            error.InvalidState,
            transaction.exec("COMMIT", &.{}, .{}),
        );
        transaction.deinit();
        try std.testing.expectEqual(turso.TransactionState.failed, transaction.state);
        try std.testing.expectError(error.InvalidState, connection.exec("SELECT 1", &.{}, .{}));
    }

    {
        var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        try std.testing.expectError(
            error.InvalidState,
            connection.execBatch("BEGIN; CREATE TABLE escaped(value INTEGER);", .{}),
        );
    }
}
