const std = @import("std");
const turso = @import("turso");

fn queryInt(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const value = try (try rows.next()).?.get(i64, 0);
    try rows.finish(null);
    return value;
}

test "structured batch mixes positional and named entries without materializing rows" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec(
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );

    const items = [_]turso.BatchItem{
        .{
            .sql = "INSERT INTO people VALUES (?1, ?2)",
            .parameters = .{ .positional = &.{
                .{ .integer = 1 },
                .{ .text = "Ada" },
            } },
        },
        .{
            .sql = "INSERT INTO people VALUES (:id, :name)",
            .parameters = .{ .named = &.{
                .{ .name = ":name", .value = .{ .text = "Grace" } },
                .{ .name = ":id", .value = .{ .integer = 2 } },
            } },
        },
        .{ .sql = "SELECT id, name FROM people ORDER BY id" },
    };

    var report: turso.BatchReport = .{};
    defer report.deinit();
    try connection.executeBatch(std.testing.allocator, &items, .{}, &report);
    try std.testing.expectEqual(@as(usize, 3), report.completed);
    try std.testing.expectEqual(@as(?usize, null), report.failed_index);
    try std.testing.expectEqual(
        turso.BatchTransactionOutcome.not_requested,
        report.transaction_outcome,
    );
    try std.testing.expectEqual(@as(u64, 1), report.entries()[0].rows_changed);
    try std.testing.expectEqual(@as(i64, 1), report.entries()[0].last_insert_row_id);
    try std.testing.expectEqual(@as(u64, 1), report.entries()[1].rows_changed);
    try std.testing.expectEqual(@as(i64, 2), report.entries()[1].last_insert_row_id);
    try std.testing.expectEqual(@as(u64, 0), report.entries()[2].rows_changed);
    try std.testing.expectEqual(@as(usize, 0), report.entries()[2].rows.len);
    try std.testing.expectEqual(@as(usize, 0), report.entries()[2].columns.len);

    try connection.executeBatch(std.testing.allocator, &.{}, .{}, &report);
    try std.testing.expectEqual(@as(usize, 0), report.completed);
    try std.testing.expectEqual(@as(usize, 0), report.entries().len);
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM people"));

    report.deinit();
    report.deinit();
}

test "structured batch materializes owned typed rows under aggregate limits" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE materialized_changes(value INTEGER)", &.{}, .{});

    const blob = [_]u8{ 0x00, 0xff, 0x7f };
    const items = [_]turso.BatchItem{
        .{
            .sql = "INSERT INTO materialized_changes VALUES (?1)",
            .parameters = .{ .positional = &.{.{ .integer = 7 }} },
        },
        .{
            .sql =
            \\SELECT NULL AS nullable, ?1 AS integer_value, ?2 AS real_value,
            \\       ?3 AS text_value, ?4 AS blob_value
            ,
            .parameters = .{ .positional = &.{
                .{ .integer = 42 },
                .{ .real = 1.5 },
                .{ .text = "owned" },
                .{ .blob = &blob },
            } },
        },
        .{
            .sql = "SELECT :value AS integer_value",
            .parameters = .{ .named = &.{
                .{ .name = ":value", .value = .{ .integer = 99 } },
            } },
        },
    };

    var report: turso.BatchReport = .{};
    defer report.deinit();
    try connection.executeBatch(
        std.testing.allocator,
        &items,
        .{ .row_policy = .{ .materialize_rows = .{
            .max_rows = 2,
            .max_items = 12,
            .max_bytes = 256,
        } } },
        &report,
    );

    try std.testing.expectEqual(@as(usize, 3), report.completed);
    try std.testing.expectEqual(@as(u64, 1), report.entries()[0].rows_changed);
    try std.testing.expectEqual(@as(i64, 1), report.entries()[0].last_insert_row_id);
    try std.testing.expectEqual(@as(usize, 0), report.entries()[0].rows.len);
    const first = &report.entries()[1];
    try std.testing.expectEqual(@as(usize, 5), first.columns.len);
    try std.testing.expectEqualStrings("nullable", first.columns[0].name);
    try std.testing.expectEqual(@as(usize, 1), first.rows.len);
    try std.testing.expect(first.rows[0].values[0] == .null_value);
    try std.testing.expectEqual(@as(i64, 42), try first.rows[0].values[1].get(i64));
    try std.testing.expectEqual(@as(f64, 1.5), try first.rows[0].values[2].get(f64));
    try std.testing.expectEqualStrings(
        "owned",
        try first.rows[0].values[3].get([]const u8),
    );
    try std.testing.expectEqualSlices(
        u8,
        &blob,
        (try first.rows[0].values[4].get(turso.Blob)).bytes,
    );
    try std.testing.expectEqual(@as(i64, 99), try report.entries()[2].rows[0].values[0].get(i64));
    report.deinit();
    report.deinit();
}

test "materialization limits stop at the failed entry and clean partial ownership" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    const queries = [_]turso.BatchItem{
        .{ .sql = "SELECT 1 AS first_value" },
        .{ .sql = "SELECT 2 AS second_value" },
    };

    var diagnostics = turso.Diagnostics{};
    var report: turso.BatchReport = .{};
    defer report.deinit();
    try std.testing.expectError(
        error.MaterializationLimitExceeded,
        connection.executeBatch(
            std.testing.allocator,
            &queries,
            .{
                .diagnostics = &diagnostics,
                .row_policy = .{ .materialize_rows = .{
                    .max_rows = 1,
                    .max_items = 8,
                    .max_bytes = 128,
                } },
            },
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(?usize, 1), report.failed_index);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "max_rows") != null);

    try std.testing.expectError(
        error.MaterializationLimitExceeded,
        connection.executeBatch(
            std.testing.allocator,
            queries[0..1],
            .{
                .diagnostics = &diagnostics,
                .row_policy = .{ .materialize_rows = .{
                    .max_rows = 1,
                    .max_items = 0,
                    .max_bytes = 128,
                } },
            },
            &report,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "max_items") != null);

    try std.testing.expectError(
        error.MaterializationLimitExceeded,
        connection.executeBatch(
            std.testing.allocator,
            queries[0..1],
            .{
                .diagnostics = &diagnostics,
                .row_policy = .{ .materialize_rows = .{
                    .max_rows = 1,
                    .max_items = 4,
                    .max_bytes = 0,
                } },
            },
            &report,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "max_bytes") != null);
}

test "non-atomic structured failures retain exact partial progress" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE unique_values(value INTEGER UNIQUE)", &.{}, .{});
    _ = try connection.exec("INSERT INTO unique_values VALUES (100)", &.{}, .{});

    var report: turso.BatchReport = .{};
    defer report.deinit();

    try std.testing.expectError(
        error.Constraint,
        connection.executeBatch(
            std.testing.allocator,
            &.{.{ .sql = "INSERT INTO unique_values VALUES (100)" }},
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), report.completed);
    try std.testing.expectEqual(@as(?usize, 0), report.failed_index);

    _ = try connection.exec("DELETE FROM unique_values", &.{}, .{});
    try std.testing.expectError(
        error.Constraint,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO unique_values VALUES (1)" },
                .{ .sql = "INSERT INTO unique_values VALUES (1)" },
                .{ .sql = "INSERT INTO unique_values VALUES (2)" },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(?usize, 1), report.failed_index);
    try std.testing.expectEqual(@as(i64, 1), try queryInt(&connection, "SELECT COUNT(*) FROM unique_values"));

    _ = try connection.exec("DELETE FROM unique_values", &.{}, .{});
    try std.testing.expectError(
        error.Constraint,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO unique_values VALUES (1)" },
                .{ .sql = "INSERT INTO unique_values VALUES (2)" },
                .{ .sql = "INSERT INTO unique_values VALUES (2)" },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), report.completed);
    try std.testing.expectEqual(@as(?usize, 2), report.failed_index);
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM unique_values"));
}

test "Connection-owned structured transactions commit or roll back explicitly" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE atomic_values(value INTEGER UNIQUE)", &.{}, .{});
    _ = try connection.exec("PRAGMA journal_mode = 'mvcc'", &.{}, .{});

    const modes = [_]turso.BatchTransaction{
        .deferred,
        .immediate,
        .exclusive,
        .concurrent,
    };
    var report: turso.BatchReport = .{};
    defer report.deinit();
    for (modes) |mode| {
        try std.testing.expectError(
            error.Constraint,
            connection.executeBatch(
                std.testing.allocator,
                &.{
                    .{ .sql = "INSERT INTO atomic_values VALUES (1)" },
                    .{ .sql = "INSERT INTO atomic_values VALUES (1)" },
                },
                .{ .transaction = mode },
                &report,
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), report.completed);
        try std.testing.expectEqual(@as(?usize, 1), report.failed_index);
        try std.testing.expectEqual(
            turso.BatchTransactionOutcome.rolled_back,
            report.transaction_outcome,
        );
        try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM atomic_values"));
    }

    try connection.executeBatch(
        std.testing.allocator,
        &.{
            .{ .sql = "INSERT INTO atomic_values VALUES (10)" },
            .{ .sql = "INSERT INTO atomic_values VALUES (20)" },
        },
        .{ .transaction = .immediate },
        &report,
    );
    try std.testing.expectEqual(
        turso.BatchTransactionOutcome.committed,
        report.transaction_outcome,
    );
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&connection, "SELECT COUNT(*) FROM atomic_values"));
}

test "structured descriptors validate before side effects and bind mismatches stop their entry" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE guarded_values(value TEXT)", &.{}, .{});

    var report: turso.BatchReport = .{};
    defer report.deinit();
    try std.testing.expectError(
        error.InteriorNul,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO guarded_values VALUES ('first')" },
                .{ .sql = "INSERT INTO guarded_values VALUES ('bad')\x00SELECT 1" },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), report.completed);
    try std.testing.expectEqual(@as(?usize, 1), report.failed_index);
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM guarded_values"));

    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(
        error.InvalidUtf8,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO guarded_values VALUES ('first')" },
                .{
                    .sql = "INSERT INTO guarded_values VALUES (?1)",
                    .parameters = .{ .positional = &.{.{ .text = &invalid_utf8 }} },
                },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), report.completed);
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM guarded_values"));

    try std.testing.expectError(
        error.DuplicateParameter,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO guarded_values VALUES ('first')" },
                .{
                    .sql = "INSERT INTO guarded_values VALUES (:value)",
                    .parameters = .{ .named = &.{
                        .{ .name = ":value", .value = .{ .text = "a" } },
                        .{ .name = ":value", .value = .{ .text = "b" } },
                    } },
                },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), report.completed);
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM guarded_values"));

    try std.testing.expectError(
        error.ParameterCountMismatch,
        connection.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO guarded_values VALUES ('first')" },
                .{
                    .sql = "INSERT INTO guarded_values VALUES (?1)",
                    .parameters = .{ .positional = &.{} },
                },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(?usize, 1), report.failed_index);
    try std.testing.expectEqual(@as(i64, 1), try queryInt(&connection, "SELECT COUNT(*) FROM guarded_values"));
}

test "Transaction batch uses existing ownership and rejects nested modes" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE tx_batch_values(value INTEGER UNIQUE)", &.{}, .{});

    var transaction = try connection.begin(.deferred, .{});
    defer transaction.deinit();
    var report: turso.BatchReport = .{};
    defer report.deinit();

    try std.testing.expectError(
        error.InvalidState,
        transaction.executeBatch(
            std.testing.allocator,
            &.{},
            .{ .transaction = .immediate },
            &report,
        ),
    );
    try std.testing.expectEqual(
        turso.BatchTransactionOutcome.existing_transaction,
        report.transaction_outcome,
    );

    try std.testing.expectError(
        error.Constraint,
        transaction.executeBatch(
            std.testing.allocator,
            &.{
                .{ .sql = "INSERT INTO tx_batch_values VALUES (1)" },
                .{ .sql = "INSERT INTO tx_batch_values VALUES (1)" },
            },
            .{},
            &report,
        ),
    );
    try std.testing.expectEqual(
        turso.BatchTransactionOutcome.existing_transaction,
        report.transaction_outcome,
    );
    try std.testing.expectEqual(turso.TransactionState.active, transaction.state);
    try transaction.rollback(null);
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT COUNT(*) FROM tx_batch_values"));
}

fn materializedBatchWithAllocator(allocator: std.mem.Allocator) !void {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var report: turso.BatchReport = .{};
    defer report.deinit();
    try connection.executeBatch(
        allocator,
        &.{
            .{ .sql = "SELECT 'first' AS value UNION ALL SELECT 'second'" },
            .{ .sql = "SELECT x'00FF' AS value" },
        },
        .{ .row_policy = .{ .materialize_rows = .{
            .max_rows = 3,
            .max_items = 8,
            .max_bytes = 128,
        } } },
        &report,
    );
}

test "allocator failures clean earlier materialized entries" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        materializedBatchWithAllocator,
        .{},
    );
}
