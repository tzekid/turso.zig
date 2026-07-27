const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    try turso.verifyRuntimeVersion(null);

    var database = try turso.Database.open(std.heap.page_allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE smoke(value TEXT)", &.{}, .{});
    _ = try connection.execParams("INSERT INTO smoke VALUES (?1)", .{"linked"}, .{});
    var rows = try connection.queryParams("SELECT value FROM smoke", .{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (!std.mem.eql(u8, "linked", try row.get([]const u8, 0))) return error.ValueMismatch;
}
