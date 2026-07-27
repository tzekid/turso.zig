const std = @import("std");
const turso = @import("turso");

const database_name = "durability.db";
const marker_timeout = std.Io.Duration.fromSeconds(15);

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const first = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, first, "--writer")) {
        const mode = args.next() orelse return error.MissingWriterMode;
        const database_path = args.next() orelse return error.MissingDatabasePath;
        const marker_path = args.next() orelse return error.MissingMarkerPath;
        if (args.next() != null) return error.TooManyArguments;
        return writer(init, mode, database_path, marker_path);
    }

    const executable = args.next() orelse return error.MissingExecutablePath;
    if (args.next() != null) return error.TooManyArguments;
    try controller(init, first, executable);
}

fn controller(init: std.process.Init, scratch_path: []const u8, executable: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = try cwd.realPathFile(init.io, executable, &executable_buffer);
    const executable_path = executable_buffer[0..executable_len];
    try cwd.createDirPath(init.io, scratch_path);
    var scratch = try cwd.openDir(init.io, scratch_path, .{});
    defer scratch.close(init.io);

    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try scratch.realPath(init.io, &absolute_buffer);
    const database_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/{s}",
        .{ absolute_buffer[0..absolute_len], database_name },
    );
    defer init.gpa.free(database_path);

    try initializeDatabase(init.gpa, database_path);
    try runWriter(init, scratch, executable_path, database_path, absolute_buffer[0..absolute_len], "committed", "committed.ready");
    try assertContents(init.gpa, database_path, true, false, true);
    try assertContents(init.gpa, database_path, true, false, false);

    try runWriter(init, scratch, executable_path, database_path, absolute_buffer[0..absolute_len], "uncommitted", "uncommitted.ready");
    try assertContents(init.gpa, database_path, true, false, true);
    try assertContents(init.gpa, database_path, true, false, false);
}

fn initializeDatabase(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{ .path = path });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectText(&connection, "PRAGMA journal_mode = WAL", "wal");
    _ = try connection.exec(
        "CREATE TABLE durability_items(id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
        &.{},
        .{},
    );
}

fn runWriter(
    init: std.process.Init,
    scratch: std.Io.Dir,
    executable: []const u8,
    database_path: []const u8,
    scratch_path: []const u8,
    mode: []const u8,
    marker: []const u8,
) !void {
    scratch.deleteFile(init.io, marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const marker_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ scratch_path, marker });
    defer init.gpa.free(marker_path);
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ executable, "--writer", mode, database_path, marker_path },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    try waitForMarker(init.io, scratch, marker);
    child.kill(init.io);
}

fn waitForMarker(io: std.Io, scratch: std.Io.Dir, marker: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(marker_timeout);
    while (true) {
        scratch.access(io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) {
                    return error.WriterMarkerTimeout;
                }
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn writer(init: std.process.Init, mode: []const u8, database_path: []const u8, marker_path: []const u8) !void {
    var database = try turso.Database.open(init.gpa, .{ .path = database_path });
    var connection = try database.connect(.{});

    _ = try connection.exec("PRAGMA synchronous = FULL", &.{}, .{});
    try expectInteger(&connection, "PRAGMA synchronous", 2);

    var transaction = try connection.begin(.immediate, .{});
    const committed = std.mem.eql(u8, mode, "committed");
    const uncommitted = std.mem.eql(u8, mode, "uncommitted");
    if (!committed and !uncommitted) return error.InvalidWriterMode;
    _ = try transaction.exec(
        "INSERT INTO durability_items(id, value) VALUES (?1, ?2)",
        &.{
            .{ .integer = if (committed) 1 else 2 },
            .{ .text = if (committed) "committed" else "uncommitted" },
        },
        .{},
    );
    if (committed) try transaction.commit(null);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = marker_path,
        .data = "ready\n",
    });

    // Deliberately retain every native handle. The parent force-terminates this
    // sole writer to exercise WAL recovery rather than graceful deinitialization.
    while (true) try std.Io.sleep(init.io, .fromSeconds(60), .awake);
}

fn assertContents(
    allocator: std.mem.Allocator,
    path: []const u8,
    committed_present: bool,
    uncommitted_present: bool,
    checkpoint: bool,
) !void {
    var database = try turso.Database.open(allocator, .{ .path = path });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectInteger(
        &connection,
        "SELECT COUNT(*) FROM durability_items WHERE id = 1 AND value = 'committed'",
        @intFromBool(committed_present),
    );
    try expectInteger(
        &connection,
        "SELECT COUNT(*) FROM durability_items WHERE id = 2 AND value = 'uncommitted'",
        @intFromBool(uncommitted_present),
    );
    if (checkpoint) {
        var rows = try connection.query("PRAGMA wal_checkpoint", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCheckpointRow;
        if (try row.get(i64, 0) != 0) return error.CheckpointBusy;
        if ((try rows.next()) != null) return error.UnexpectedCheckpointRow;
        try rows.finish(null);
    }
}

fn expectInteger(connection: *turso.Connection, sql: []const u8, expected: i64) !void {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (try row.get(i64, 0) != expected) return error.UnexpectedInteger;
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
}

fn expectText(connection: *turso.Connection, sql: []const u8, expected: []const u8) !void {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (!std.mem.eql(u8, try row.get([]const u8, 0), expected)) return error.UnexpectedText;
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
}
