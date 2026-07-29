const std = @import("std");
const turso = @import("turso");

pub fn main(init: std.process.Init) !void {
    var random_bytes: [12]u8 = undefined;
    init.io.random(&random_bytes);
    const random_name = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(
        init.gpa,
        ".turso-zig-file-{s}",
        .{random_name},
    );
    defer init.gpa.free(temp_name);

    const cwd = std.Io.Dir.cwd();
    var temp_dir = try cwd.createDirPathOpen(init.io, temp_name, .{});
    defer {
        temp_dir.close(init.io);
        cwd.deleteTree(init.io, temp_name) catch |err| {
            std.debug.print(
                "warning: could not remove the example database: {s}\n",
                .{@errorName(err)},
            );
        };
    }

    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temp_dir.realPath(init.io, &absolute_buffer);
    const database_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/people.db",
        .{absolute_buffer[0..absolute_len]},
    );
    defer init.gpa.free(database_path);

    try createDatabase(init.gpa, database_path);
    try reopenDatabase(init.gpa, database_path);
}

fn createDatabase(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{ .path = path });
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.execParams(
        "INSERT INTO people(name) VALUES (?1)",
        .{"Ada"},
        .{},
    );

    std.debug.print(
        "inserted row {d}, closing database\n",
        .{try connection.lastInsertRowId()},
    );
}

fn reopenDatabase(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{ .path = path });
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    var rows = try connection.query(
        "SELECT id, name FROM people",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()) orelse return error.ExpectedRow;
    std.debug.print("reopened row {d}: {s}\n", .{
        try row.get(i64, 0),
        try row.get([]const u8, 1),
    });
}
