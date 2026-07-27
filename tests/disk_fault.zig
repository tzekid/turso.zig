const std = @import("std");
const turso = @import("turso");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const mode = args.next() orelse return error.MissingMode;
    const database_path = args.next() orelse return error.MissingDatabasePath;
    if (args.next() != null) return error.TooManyArguments;
    if (!std.mem.eql(u8, mode, "enospc") and !std.mem.eql(u8, mode, "short")) {
        return error.InvalidMode;
    }

    try initialize(init.gpa, database_path);
    try injectTransactionFailure(init.gpa, database_path);
    try verifyAndRecover(init.gpa, database_path);
    try verifyFinalContents(init.gpa, database_path);
}

fn initialize(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{
        .path = path,
        .vfs = .syscall,
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectText(&connection, "PRAGMA journal_mode = WAL", "wal");
    _ = try connection.exec("PRAGMA synchronous = FULL", &.{}, .{});
    _ = try connection.exec(
        "CREATE TABLE fault_items(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.exec(
        "INSERT INTO fault_items(id, payload) VALUES (1, x'73656564')",
        &.{},
        .{},
    );
}

fn injectTransactionFailure(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{
        .path = path,
        .vfs = .syscall,
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectInteger(&connection, "SELECT COUNT(*) FROM fault_items", 1);
    _ = try connection.exec("PRAGMA synchronous = FULL", &.{}, .{});

    const payload = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(payload);
    @memset(payload, 0xa5);

    var transaction = try connection.begin(.immediate, .{});
    defer transaction.deinit();
    var diagnostics = turso.Diagnostics{};

    if (setenv("TURSO_DISK_FAULT_ARMED", "1", 1) != 0) {
        return error.SetEnvironmentFailed;
    }
    var armed = true;
    defer if (armed) {
        _ = unsetenv("TURSO_DISK_FAULT_ARMED");
    };

    var observed_failure = false;
    _ = transaction.exec(
        "INSERT INTO fault_items(id, payload) VALUES (2, ?1), (3, ?1)",
        &.{.{ .blob = payload }},
        .{ .diagnostics = &diagnostics },
    ) catch |err| {
        try acceptInjectedError(err, diagnostics, path);
        observed_failure = true;
    };
    if (!observed_failure) {
        transaction.commit(&diagnostics) catch |err| {
            try acceptInjectedError(err, diagnostics, path);
            observed_failure = true;
        };
    }

    _ = unsetenv("TURSO_DISK_FAULT_ARMED");
    armed = false;
    if (!observed_failure) return error.ExpectedInjectedWriteFailure;

    // The wrapper keeps ownership active after a failed transaction operation.
    // Best-effort deinit rolls it back (or poisons only this closing connection)
    // after fault injection has been disabled.
    transaction.deinit();
}

fn acceptInjectedError(
    err: turso.Error,
    diagnostics: turso.Diagnostics,
    path: []const u8,
) !void {
    switch (err) {
        error.DatabaseFull => try expectStatus(diagnostics.status, .database_full),
        error.Io => try expectStatus(diagnostics.status, .io_error),
        else => return err,
    }
    if (diagnostics.text().len == 0) return error.MissingDiagnostics;
    if (std.mem.indexOf(u8, diagnostics.text(), path) != null) {
        return error.DatabasePathLeakedInDiagnostics;
    }
}

fn expectStatus(actual: turso.Status, expected: turso.Status) !void {
    if (actual != expected) return error.UnexpectedStatus;
}

fn verifyAndRecover(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{
        .path = path,
        .vfs = .syscall,
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectText(&connection, "PRAGMA integrity_check", "ok");
    try expectInteger(&connection, "SELECT COUNT(*) FROM fault_items", 1);
    try expectInteger(
        &connection,
        "SELECT COUNT(*) FROM fault_items WHERE id IN (2, 3)",
        0,
    );
    _ = try connection.exec(
        "INSERT INTO fault_items(id, payload) VALUES (4, x'7265636f7665726564')",
        &.{},
        .{},
    );
}

fn verifyFinalContents(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try turso.Database.open(allocator, .{
        .path = path,
        .vfs = .syscall,
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try expectText(&connection, "PRAGMA integrity_check", "ok");
    try expectInteger(&connection, "SELECT COUNT(*) FROM fault_items", 2);
    try expectInteger(
        &connection,
        "SELECT COUNT(*) FROM fault_items WHERE id IN (1, 4)",
        2,
    );
    try expectInteger(
        &connection,
        "SELECT COUNT(*) FROM fault_items WHERE id IN (2, 3)",
        0,
    );
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
    if (!std.mem.eql(u8, try row.get([]const u8, 0), expected)) {
        return error.UnexpectedText;
    }
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
}
