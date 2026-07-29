const std = @import("std");
const turso = @import("turso");

pub fn main(init: std.process.Init) !void {
    var database = try turso.Database.open(
        init.gpa,
        .{ .path = ":memory:" },
    );
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    var diagnostics = turso.Diagnostics{};
    if (connection.exec(
        "SELECT * FROM table_that_does_not_exist",
        &.{},
        .{ .diagnostics = &diagnostics },
    )) |_| {
        return error.ExpectedQueryFailure;
    } else |err| {
        std.debug.print("expected {s}: {s}\n", .{
            @errorName(err),
            diagnostics.text(),
        });
    }

    try connection.setBusyTimeout(250, &diagnostics);
    if (!try connection.isAutocommit()) return error.ExpectedAutocommit;

    _ = try connection.exec(
        "CREATE TABLE answers(id INTEGER PRIMARY KEY, value INTEGER)",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    _ = try connection.execParams(
        "INSERT INTO answers(value) VALUES (?1)",
        .{@as(i64, 42)},
        .{ .diagnostics = &diagnostics },
    );
    const inserted_id = try connection.lastInsertRowId();

    var statement = try connection.prepare(
        "SELECT value AS answer FROM answers WHERE id = :id",
        .{ .diagnostics = &diagnostics },
    );
    defer statement.deinit();

    var parameter = try statement.parameterInfo(init.gpa, 1);
    defer parameter.deinit(init.gpa);
    var column = try statement.columnInfo(init.gpa, 0);
    defer column.deinit(init.gpa);

    var rows = try statement.queryParams(
        .{ .id = inserted_id },
        &diagnostics,
    );
    defer rows.deinit();
    const row = (try rows.nextWithDiagnostics(&diagnostics)) orelse
        return error.ExpectedRow;

    std.debug.print(
        "parameter {s}, column {s}, value {d}\n",
        .{
            parameter.name orelse "(anonymous)",
            column.name,
            try row.get(i64, 0),
        },
    );
}
