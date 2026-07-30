const std = @import("std");
const turso = @import("turso");

const correct_key = "b1bbfda4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc76327";
const wrong_key = "aaaaaaa4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc76327";
const log_secret = "turso-zig-log-secret-7e4980f1";

const LogCapture = struct {
    calls: usize = 0,
    message: [512]u8 = undefined,
    message_len: usize = 0,
    target: [256]u8 = undefined,
    target_len: usize = 0,
    file: [512]u8 = undefined,
    file_len: usize = 0,
    saw_level: [6]bool = @splat(false),
    saw_secret: bool = false,
};

var capture_mutex: std.atomic.Mutex = .unlocked;
var capture = LogCapture{};

/// A production logger callback must be allocation-free or use its own
/// synchronized allocator, copy retained fields, be thread-safe, and not panic.
fn testLogger(log: turso.Log) void {
    lockCapture();
    defer capture_mutex.unlock();

    capture.calls += 1;
    copyRetained(&capture.message, &capture.message_len, log.message);
    copyRetained(&capture.target, &capture.target_len, log.target);
    copyRetained(&capture.file, &capture.file_len, log.file);
    capture.saw_level[levelIndex(log.level)] = true;
    capture.saw_secret = capture.saw_secret or
        containsSecret(log.message) or
        containsSecret(log.target) or
        containsSecret(log.file);
}

fn containsSecret(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, log_secret) != null or
        std.mem.indexOf(u8, bytes, correct_key) != null or
        std.mem.indexOf(u8, bytes, wrong_key) != null;
}

fn lockCapture() void {
    while (!capture_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn copyRetained(destination: anytype, len: *usize, source: []const u8) void {
    if (source.len == 0) return;
    const copied = @min(destination.len, source.len);
    @memcpy(destination[0..copied], source[0..copied]);
    len.* = copied;
}

fn levelIndex(level: turso.TracingLevel) usize {
    return switch (level) {
        .error_level => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
        .trace => 4,
        .unknown => 5,
    };
}

test "process-global logger copies borrowed fields maps levels and rejects replacement" {
    var diagnostics = turso.Diagnostics{};
    try turso.setup(.{
        .level = .trace,
        .logger = testLogger,
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expectError(
        error.AlreadySetup,
        turso.setup(.{ .level = .error_level, .diagnostics = &diagnostics }),
    );
    try std.testing.expect(diagnostics.text().len != 0);

    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var statement = try connection.prepare("SELECT :logged_parameter", .{});
    statement.deinit();
    var rows = try connection.query("SELECT ?1", &.{.{ .text = log_secret }}, .{});
    while (try rows.next()) |_| {}
    try rows.finish(null);

    var concurrent_database = try turso.Database.open(std.heap.page_allocator, .{ .path = ":memory:" });
    defer concurrent_database.deinit();
    var concurrent_context = LoggerConcurrentContext{ .database = &concurrent_database };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, loggerWorker, .{&concurrent_context});
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), concurrent_context.failures.load(.acquire));

    lockCapture();
    defer capture_mutex.unlock();
    try std.testing.expect(capture.calls != 0);
    try std.testing.expect(capture.message_len != 0);
    try std.testing.expect(capture.target_len != 0);
    // The native ABI has five defined levels. No normal event may be mapped to
    // the wrapper's forward-compatible unknown value.
    try std.testing.expect(!capture.saw_level[levelIndex(.unknown)]);
    var saw_known = false;
    for (capture.saw_level[0..5]) |seen| saw_known = saw_known or seen;
    try std.testing.expect(saw_known);
    try std.testing.expect(!capture.saw_secret);
}

const LoggerConcurrentContext = struct {
    database: *turso.Database,
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn loggerWorker(context: *LoggerConcurrentContext) void {
    var connection = context.database.connect(.{}) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
        return;
    };
    defer connection.deinit();
    _ = connection.exec("SELECT 1", &.{}, .{}) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
    };
}

test "encrypted file reopens with correct key and rejects wrong key without disclosure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/encrypted.db",
        .{absolute_buffer[0..absolute_len]},
    );
    defer std.testing.allocator.free(path);

    const encryption = turso.EncryptionOptions{
        .cipher = .aegis256,
        .hex_key = correct_key,
    };
    {
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = path,
            .encryption = encryption,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        _ = try connection.exec(
            "CREATE TABLE secrets(id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
            &.{},
            .{},
        );
        _ = try connection.exec(
            "INSERT INTO secrets(value) VALUES (?1)",
            &.{.{ .text = "classified payload" }},
            .{},
        );
    }

    const encrypted_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer std.testing.allocator.free(encrypted_bytes);
    try std.testing.expect(std.mem.indexOf(u8, encrypted_bytes, "classified payload") == null);

    {
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = path,
            .encryption = encryption,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        var rows = try connection.query("SELECT value FROM secrets", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try std.testing.expectEqualStrings("classified payload", try row.get([]const u8, 0));
        try std.testing.expect((try rows.next()) == null);
        try rows.finish(null);
    }

    var diagnostics = turso.Diagnostics{};
    const rejected = try wrongKeyIsRejected(path, &diagnostics);
    try std.testing.expect(rejected);
    try expectDiagnosticsContainNoKey(&diagnostics);
    lockCapture();
    defer capture_mutex.unlock();
    try std.testing.expect(!capture.saw_secret);
}

test "cipher and key validation is local and never reports key material" {
    var diagnostics = turso.Diagnostics{};
    const short_key = "00112233";
    try std.testing.expectError(
        error.InvalidHexKeyLength,
        turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .encryption = .{
                .cipher = .aes256gcm,
                .hex_key = short_key,
            },
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), short_key) == null);
    try expectDiagnosticsContainNoKey(&diagnostics);

    const invalid_key = "b1bbfda4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc7632g";
    try std.testing.expectError(
        error.InvalidHexKey,
        turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .encryption = .{
                .cipher = .aegis256,
                .hex_key = invalid_key,
            },
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), invalid_key) == null);
    try expectDiagnosticsContainNoKey(&diagnostics);
}

test "every advertised encryption cipher opens and executes" {
    inline for (std.meta.tags(turso.EncryptionCipher)) |cipher| {
        var key: [64]u8 = undefined;
        @memset(&key, 'a');
        const key_len = cipher.keyBytes() * 2;
        var database = try turso.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .encryption = .{ .cipher = cipher, .hex_key = key[0..key_len] },
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        _ = try connection.exec("SELECT 1", &.{}, .{});
    }
}

fn wrongKeyIsRejected(path: []const u8, diagnostics: *turso.Diagnostics) !bool {
    var database = turso.Database.open(std.testing.allocator, .{
        .path = path,
        .encryption = .{
            .cipher = .aegis256,
            .hex_key = wrong_key,
        },
        .diagnostics = diagnostics,
    }) catch {
        try expectDiagnosticsContainNoKey(diagnostics);
        return true;
    };
    defer database.deinit();

    var connection = database.connect(.{ .diagnostics = diagnostics }) catch {
        try expectDiagnosticsContainNoKey(diagnostics);
        return true;
    };
    defer connection.deinit();

    var rows = connection.query(
        "SELECT value FROM secrets",
        &.{},
        .{ .diagnostics = diagnostics },
    ) catch {
        try expectDiagnosticsContainNoKey(diagnostics);
        return true;
    };
    defer rows.deinit();

    _ = rows.nextWithDiagnostics(diagnostics) catch {
        try expectDiagnosticsContainNoKey(diagnostics);
        return true;
    };
    return false;
}

fn expectDiagnosticsContainNoKey(diagnostics: *const turso.Diagnostics) !void {
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), correct_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), wrong_key) == null);
}
