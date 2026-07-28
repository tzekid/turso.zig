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
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );

    var report: turso.BatchReport = .{};
    defer report.deinit();

    // Without a requested transaction, a later failure leaves earlier entries
    // committed and the report identifies both facts.
    connection.executeBatch(
        std.heap.page_allocator,
        &.{
            .{
                .sql = "INSERT INTO people VALUES (?1, ?2)",
                .parameters = .{ .positional = &.{
                    .{ .integer = 1 },
                    .{ .text = "Ada" },
                } },
            },
            .{ .sql = "INSERT INTO people VALUES (1, 'duplicate')" },
        },
        .{},
        &report,
    ) catch |err| switch (err) {
        error.Constraint => std.debug.print(
            "non-atomic: {d} completed, failed at {d}\n",
            .{ report.completed, report.failed_index.? },
        ),
        else => return err,
    };

    // An explicit transaction commits all entries together. Materialized rows
    // are allocator-owned and bounded by limits chosen at the call site.
    try connection.executeBatch(
        std.heap.page_allocator,
        &.{
            .{ .sql = "INSERT INTO people VALUES (2, 'Grace')" },
            .{ .sql = "INSERT INTO people VALUES (3, 'Linus')" },
            .{ .sql = "SELECT id, name FROM people ORDER BY id" },
        },
        .{
            .transaction = .immediate,
            .row_policy = .{ .materialize_rows = .{
                .max_rows = 3,
                .max_items = 16,
                .max_bytes = 512,
            } },
        },
        &report,
    );

    std.debug.print("atomic: {s}, rows:\n", .{@tagName(report.transaction_outcome)});
    for (report.entries()[2].rows) |row| {
        std.debug.print("  {d}: {s}\n", .{
            try row.values[0].get(i64),
            try row.values[1].get([]const u8),
        });
    }
}
