const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var database = try turso.Database.open(arena.allocator(), .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec(
        "CREATE TABLE ledger(id INTEGER PRIMARY KEY, note TEXT NOT NULL)",
        &.{},
        .{},
    );

    // An active Transaction owns the Connection exclusively. Its deinit rolls
    // back best-effort if control leaves the scope before commit or rollback.
    simulatedFailure(&connection) catch |err| {
        if (err != error.SimulatedFailure) return err;
    };

    var committed = try connection.begin(.immediate, .{});
    defer committed.deinit();
    _ = try committed.exec(
        "INSERT INTO ledger(note) VALUES (?1)",
        &.{.{ .text = "committed" }},
        .{},
    );
    try committed.commit(null);

    var discarded = try connection.begin(.immediate, .{});
    defer discarded.deinit();
    _ = try discarded.exec(
        "INSERT INTO ledger(note) VALUES (?1)",
        &.{.{ .text = "explicitly rolled back" }},
        .{},
    );
    try discarded.rollback(null);

    var rows = try connection.query("SELECT note FROM ledger ORDER BY id", &.{}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        std.debug.print("{s}\n", .{try row.get([]const u8, 0)});
    }
    try rows.finish(null);
}

fn simulatedFailure(connection: *turso.Connection) !void {
    var transaction = try connection.begin(.deferred, .{});
    defer transaction.deinit();
    _ = try transaction.exec(
        "INSERT INTO ledger(note) VALUES (?1)",
        &.{.{ .text = "rolled back by deinit" }},
        .{},
    );
    return error.SimulatedFailure;
}
