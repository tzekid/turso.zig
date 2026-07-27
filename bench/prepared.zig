const std = @import("std");
const turso = @import("turso");

const prepared_iterations = 10_000;
const one_shot_iterations = 1_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    var output_buffer: [1024]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(io, &output_buffer);
    const output = &output_writer.interface;
    defer output.flush() catch {};

    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE bench(value INTEGER)", &.{}, .{});

    var transaction = try connection.begin(.immediate, .{});
    var insert = try transaction.prepare("INSERT INTO bench VALUES (?1)", .{});
    const prepared_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..prepared_iterations) |index| {
        try insert.bindParams(.{@as(i64, @intCast(index))}, null);
        _ = try insert.execute(null);
        if (index + 1 != prepared_iterations) try insert.reset(null);
    }
    const prepared_elapsed = std.Io.Clock.awake.now(io).nanoseconds - prepared_start;
    insert.deinit();
    try transaction.commit(null);
    transaction.deinit();

    const one_shot_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..one_shot_iterations) |index| {
        _ = try connection.exec(
            "INSERT INTO bench VALUES (?1)",
            &.{.{ .integer = @intCast(index) }},
            .{},
        );
    }
    const one_shot_elapsed = std.Io.Clock.awake.now(io).nanoseconds - one_shot_start;

    var rows = try connection.query("SELECT value FROM bench", &.{}, .{});
    const rows_start = std.Io.Clock.awake.now(io).nanoseconds;
    var row_count: usize = 0;
    var checksum: i64 = 0;
    while (try rows.next()) |row| {
        checksum +%= try row.get(i64, 0);
        row_count += 1;
    }
    const rows_elapsed = std.Io.Clock.awake.now(io).nanoseconds - rows_start;
    try rows.finish(null);
    rows.deinit();
    std.mem.doNotOptimizeAway(checksum);

    try output.print(
        "prepared bind/execute/reset: {d} ns/op ({d} iterations)\n" ++
            "one-shot prepare/bind/execute: {d} ns/op ({d} iterations)\n" ++
            "borrowed row step/decode: {d} ns/row ({d} rows)\n",
        .{
            @divTrunc(prepared_elapsed, prepared_iterations),
            prepared_iterations,
            @divTrunc(one_shot_elapsed, one_shot_iterations),
            one_shot_iterations,
            @divTrunc(rows_elapsed, row_count),
            row_count,
        },
    );
}
