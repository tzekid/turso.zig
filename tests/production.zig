const std = @import("std");
const builtin = @import("builtin");
const turso = @import("turso");

const thread_count = 8;
const iterations_per_thread = 64;

fn temporaryPath(
    temporary: *std.testing.TmpDir,
    allocator: std.mem.Allocator,
    basename: []const u8,
) ![]u8 {
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ absolute_buffer[0..absolute_len], basename },
    );
}

fn queryInt(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    const result = try row.get(i64, 0);
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
    return result;
}

fn openPlatformNativeVfs(
    path: []const u8,
    vfs: turso.Vfs,
    diagnostics: *turso.Diagnostics,
) !turso.Database {
    return turso.Database.open(std.testing.allocator, .{
        .path = path,
        .vfs = vfs,
        .diagnostics = diagnostics,
    }) catch |err| {
        const message = diagnostics.text();
        if (platformNativeBackendUnavailable(
            builtin.os.tag,
            builtin.cpu.arch,
            err,
            message,
        )) return error.SkipZigTest;
        std.debug.print(
            "platform-native VFS open failed ({s}): {s}\n",
            .{ @errorName(err), message },
        );
        return err;
    };
}

fn platformNativeBackendUnavailable(
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    err: anyerror,
    message: []const u8,
) bool {
    const backend_initialization_failed =
        err == error.TursoFailure and
        (std.mem.indexOf(u8, message, "unable to create io_uring backend") != null or
            std.mem.indexOf(u8, message, "unable to create win_iocp backend") != null);

    // The pinned SDK Kit's io_uring backend can initialize and perform writes
    // on GitHub's Linux ARM runner, but its first existing-file reopen is
    // rejected by the host kernel with this exact completion-queue diagnostic.
    // Keep the exception architecture- and message-specific; syscall VFS
    // persistence remains a blocking test on the same runner.
    const linux_arm_io_uring_rejected =
        os == .linux and arch == .aarch64 and err == error.Io and
        std.mem.eql(u8, message, "I/O error (io_uring_cqe): invalid input parameter");

    return backend_initialization_failed or linux_arm_io_uring_rejected;
}

test "platform-native backend exceptions remain narrowly classified" {
    try std.testing.expect(platformNativeBackendUnavailable(
        .linux,
        .aarch64,
        error.Io,
        "I/O error (io_uring_cqe): invalid input parameter",
    ));
    try std.testing.expect(!platformNativeBackendUnavailable(
        .linux,
        .x86_64,
        error.Io,
        "I/O error (io_uring_cqe): invalid input parameter",
    ));
    try std.testing.expect(!platformNativeBackendUnavailable(
        .linux,
        .aarch64,
        error.Io,
        "I/O error (io_uring_cqe): permission denied",
    ));
    try std.testing.expect(platformNativeBackendUnavailable(
        .windows,
        .x86_64,
        error.TursoFailure,
        "unable to create win_iocp backend: unsupported",
    ));
}

test "syscall VFS commits survive a full close and reopen" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(&temporary, std.testing.allocator, "durable.db");
    defer std.testing.allocator.free(path);

    {
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = path,
            .vfs = .syscall,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();

        _ = try connection.exec(
            "CREATE TABLE durable_items(id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
            &.{},
            .{},
        );
        var transaction = try connection.begin(.immediate, .{});
        defer transaction.deinit();
        _ = try transaction.exec(
            "INSERT INTO durable_items VALUES (1, ?1), (2, ?2), (3, ?3)",
            &.{
                .{ .text = "first" },
                .{ .text = "second" },
                .{ .text = "third" },
            },
            .{},
        );
        try transaction.commit(null);
    }

    {
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = path,
            .vfs = .syscall,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();

        try std.testing.expectEqual(@as(i64, 3), try queryInt(&connection, "SELECT COUNT(*) FROM durable_items"));
        var rows = try connection.query(
            "SELECT value FROM durable_items ORDER BY id",
            &.{},
            .{},
        );
        defer rows.deinit();
        for ([_][]const u8{ "first", "second", "third" }) |expected| {
            const row = (try rows.next()).?;
            try std.testing.expectEqualStrings(expected, try row.get([]const u8, 0));
        }
        try std.testing.expect((try rows.next()) == null);
        try rows.finish(null);
    }
}

test "platform-native asynchronous VFS supports blocking safe operations" {
    const vfs: turso.Vfs = switch (builtin.os.tag) {
        .linux => .io_uring,
        .windows => .experimental_win_iocp,
        else => return error.SkipZigTest,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(&temporary, std.testing.allocator, "native-vfs.db");
    defer std.testing.allocator.free(path);

    var diagnostics = turso.Diagnostics{};
    {
        var database = try openPlatformNativeVfs(path, vfs, &diagnostics);
        defer database.deinit();
        var connection = try database.connect(.{ .diagnostics = &diagnostics });
        defer connection.deinit();
        _ = try connection.exec(
            "CREATE TABLE native_vfs_items(value INTEGER NOT NULL)",
            &.{},
            .{ .diagnostics = &diagnostics },
        );
        _ = try connection.exec(
            "INSERT INTO native_vfs_items VALUES (17), (25)",
            &.{},
            .{ .diagnostics = &diagnostics },
        );
        try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    }

    var database = try openPlatformNativeVfs(path, vfs, &diagnostics);
    defer database.deinit();
    var connection = try database.connect(.{ .diagnostics = &diagnostics });
    defer connection.deinit();
    try std.testing.expectEqual(@as(i64, 42), try queryInt(
        &connection,
        "SELECT SUM(value) FROM native_vfs_items",
    ));
}

test "memory VFS supports an isolated database lifecycle" {
    var database = try turso.Database.open(std.testing.allocator, .{
        .path = "production-memory-vfs",
        .vfs = .memory,
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE memory_items(value INTEGER)", &.{}, .{});
    _ = try connection.exec("INSERT INTO memory_items VALUES (41), (42), (43)", &.{}, .{});
    try std.testing.expectEqual(@as(i64, 126), try queryInt(&connection, "SELECT SUM(value) FROM memory_items"));
}

test "non-database input reports the native not-a-database taxonomy" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "notadb.db",
        .data = "this is deliberately not a SQLite or Turso database\n" ** 8,
    });
    const path = try temporaryPath(&temporary, std.testing.allocator, "notadb.db");
    defer std.testing.allocator.free(path);

    var diagnostics = turso.Diagnostics{};
    var database = turso.Database.open(std.testing.allocator, .{
        .path = path,
        .vfs = .automatic,
        .diagnostics = &diagnostics,
    }) catch |err| {
        // The pinned SDK Kit currently reports malformed headers as its
        // generic failure status during open. Keep accepting the two more
        // specific statuses so this test tightens automatically when upstream
        // begins emitting them through the C ABI.
        try std.testing.expect(
            err == error.TursoFailure or err == error.NotDatabase or err == error.Corrupt,
        );
        try std.testing.expect(diagnostics.text().len != 0);
        return;
    };
    defer database.deinit();
    var connection = try database.connect(.{ .diagnostics = &diagnostics });
    defer connection.deinit();
    const result = connection.query("SELECT * FROM sqlite_schema", &.{}, .{ .diagnostics = &diagnostics });
    try std.testing.expectError(error.NotDatabase, result);
    try std.testing.expect(diagnostics.text().len != 0);
}

test "read-only filesystem rejects database mutation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const path = try temporaryPath(&temporary, std.testing.allocator, "readonly.db");
    defer std.testing.allocator.free(path);

    {
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = path,
            .vfs = .syscall,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        _ = try connection.exec("CREATE TABLE readonly_items(value INTEGER)", &.{}, .{});
    }

    const file_permissions = (try temporary.dir.statFile(std.testing.io, "readonly.db", .{})).permissions;
    const dir_permissions = (try temporary.dir.stat(std.testing.io)).permissions;
    try temporary.dir.setFilePermissions(
        std.testing.io,
        "readonly.db",
        file_permissions.setReadOnly(true),
        .{},
    );
    try temporary.dir.setPermissions(std.testing.io, dir_permissions.setReadOnly(true));
    defer {
        temporary.dir.setPermissions(std.testing.io, dir_permissions) catch {};
        temporary.dir.setFilePermissions(
            std.testing.io,
            "readonly.db",
            file_permissions,
            .{},
        ) catch {};
    }

    var diagnostics = turso.Diagnostics{};
    var database = turso.Database.open(std.testing.allocator, .{
        .path = path,
        .vfs = .syscall,
        .diagnostics = &diagnostics,
    }) catch |err| {
        try std.testing.expect(err == error.ReadOnly or err == error.Io or err == error.TursoFailure);
        try std.testing.expect(diagnostics.text().len != 0);
        return;
    };
    defer database.deinit();
    var connection = try database.connect(.{ .diagnostics = &diagnostics });
    defer connection.deinit();
    const mutation = connection.exec(
        "INSERT INTO readonly_items VALUES (1)",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    _ = mutation catch |err| {
        try std.testing.expect(err == error.ReadOnly or err == error.Io or err == error.TursoFailure);
        try std.testing.expect(diagnostics.text().len != 0);
        return;
    };
    return error.ExpectedReadonlyFailure;
}

test "large value and large transaction commit atomically" {
    const allocator = std.testing.allocator;
    const large_blob = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_blob);
    for (large_blob, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);

    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec(
        "CREATE TABLE stress_items(id INTEGER PRIMARY KEY, payload BLOB)",
        &.{},
        .{},
    );

    var transaction = try connection.begin(.immediate, .{});
    defer transaction.deinit();
    var index: usize = 0;
    while (index < 1024) : (index += 1) {
        _ = try transaction.exec(
            "INSERT INTO stress_items(id, payload) VALUES (?1, NULL)",
            &.{.{ .integer = @intCast(index + 1) }},
            .{},
        );
    }
    _ = try transaction.exec(
        "UPDATE stress_items SET payload = ?1 WHERE id = 1024",
        &.{.{ .blob = large_blob }},
        .{},
    );
    try transaction.commit(null);

    try std.testing.expectEqual(@as(i64, 1024), try queryInt(&connection, "SELECT COUNT(*) FROM stress_items"));
    try std.testing.expectEqual(@as(i64, 1024 * 1024), try queryInt(
        &connection,
        "SELECT length(payload) FROM stress_items WHERE id = 1024",
    ));
    var rows = try connection.query(
        "SELECT payload FROM stress_items WHERE id = 1024",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqualSlices(u8, large_blob, (try row.get(turso.Blob, 0)).bytes);
    try rows.finish(null);
}

test "repeated complete lifecycles fit a reset fixed allocator" {
    var storage: [4 * 1024]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        {
            var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
            defer database.deinit();
            var connection = try database.connect(.{});
            defer connection.deinit();
            _ = try connection.exec("SELECT 1", &.{}, .{});
        }
        // A reset models a bounded per-request arena. Reset only after every
        // native owner has been torn down, so no live wrapper can retain the
        // reclaimed Zig storage across iterations.
        fixed.reset();
    }
}

const FanoutContext = struct {
    database: *turso.Database,
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn fanoutIteration(database: *turso.Database, expected: i64) !void {
    var connection = try database.connect(.{});
    defer connection.deinit();
    var rows = try connection.query(
        "SELECT ?1 + 1",
        &.{.{ .integer = expected - 1 }},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (try row.get(i64, 0) != expected) return error.UnexpectedValue;
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
}

fn fanoutWorker(context: *FanoutContext, worker_index: usize) void {
    var iteration: usize = 0;
    while (iteration < iterations_per_thread) : (iteration += 1) {
        const expected: i64 = @intCast(worker_index * iterations_per_thread + iteration + 1);
        fanoutIteration(context.database, expected) catch {
            _ = context.failures.fetchAdd(1, .monotonic);
            return;
        };
    }
}

test "independent connections sustain multi-thread fan-out" {
    var database = try turso.Database.open(std.heap.page_allocator, .{
        .path = "production-concurrent-memory-vfs",
        .vfs = .memory,
    });
    defer database.deinit();
    var context = FanoutContext{ .database = &database };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, fanoutWorker, .{ &context, index });
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), context.failures.load(.acquire));
}

test "zero-timeout writers expose reliable Busy contention and recover" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(&temporary, std.testing.allocator, "busy-production.db");
    defer std.testing.allocator.free(path);

    var first_database = try turso.Database.open(std.testing.allocator, .{
        .path = path,
        .vfs = .automatic,
    });
    defer first_database.deinit();
    var second_database = try turso.Database.open(std.testing.allocator, .{
        .path = path,
        .vfs = .automatic,
    });
    defer second_database.deinit();
    var first = try first_database.connect(.{ .busy_timeout_ms = 0 });
    defer first.deinit();
    var second = try second_database.connect(.{ .busy_timeout_ms = 0 });
    defer second.deinit();
    _ = try first.exec("CREATE TABLE busy_items(value INTEGER)", &.{}, .{});

    var holder = try first.begin(.immediate, .{});
    defer holder.deinit();
    _ = try holder.exec("INSERT INTO busy_items VALUES (1)", &.{}, .{});
    try std.testing.expectError(error.Busy, second.begin(.immediate, .{}));

    try second.setBusyTimeout(100, null);
    const wait_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try std.testing.expectError(error.Busy, second.begin(.immediate, .{}));
    const waited_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - wait_start;
    try std.testing.expect(waited_ns >= 50 * std.time.ns_per_ms);
    try std.testing.expect(waited_ns <= 2 * std.time.ns_per_s);
    try holder.commit(null);

    var recovered = try second.begin(.immediate, .{});
    defer recovered.deinit();
    _ = try recovered.exec("INSERT INTO busy_items VALUES (2)", &.{}, .{});
    try recovered.commit(null);
    try std.testing.expectEqual(@as(i64, 2), try queryInt(&second, "SELECT COUNT(*) FROM busy_items"));
}
