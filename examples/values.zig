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

    _ = try connection.exec(
        "CREATE TABLE sample(" ++
            "missing INTEGER, count INTEGER, ratio REAL, " ++
            "label TEXT, payload BLOB)",
        &.{},
        .{},
    );

    const payload = [_]u8{ 0x00, 0x7f, 0xff };
    _ = try connection.execParams(
        "INSERT INTO sample VALUES (?1, ?2, ?3, ?4, ?5)",
        .{
            null,
            @as(i64, 42),
            @as(f64, 1.5),
            "borrowed while this row is current",
            turso.Blob.init(&payload),
        },
        .{},
    );

    var rows = try connection.query(
        "SELECT missing, count, ratio, label, payload FROM sample",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()) orelse return error.ExpectedRow;
    const missing = try row.get(?i64, 0);
    const count = try row.get(i64, 1);
    const ratio = try row.get(f64, 2);

    // These copies remain valid after the native row is advanced or released.
    var label = try row.toOwned(init.gpa, 3);
    defer label.deinit(init.gpa);
    var owned_payload = try row.toOwned(init.gpa, 4);
    defer owned_payload.deinit(init.gpa);

    try rows.finish(null);

    std.debug.print(
        "null={any}, integer={d}, real={d}, text=\"{s}\", blob={any}\n",
        .{
            missing,
            count,
            ratio,
            try label.get([]const u8),
            (try owned_payload.get(turso.Blob)).slice(),
        },
    );
}
