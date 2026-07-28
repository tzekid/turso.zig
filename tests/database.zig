const std = @import("std");
const database_mod = @import("turso");

test "in-memory database connects closes and cleans up" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();

    var connection = try database.connect(.{ .busy_timeout_ms = 1_000 });
    defer connection.deinit();
    try std.testing.expect(try connection.isAutocommit());
    try connection.close(null);
}

test "native prepare errors preserve diagnostics and clear after success" {
    var diagnostics = database_mod.Diagnostics{};
    var database = try database_mod.Database.open(std.testing.allocator, .{
        .path = ":memory:",
        .diagnostics = &diagnostics,
    });
    defer database.deinit();
    var connection = try database.connect(.{ .diagnostics = &diagnostics });
    defer connection.deinit();

    try std.testing.expectError(
        error.TursoFailure,
        connection.prepare("SELECT FROM", .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expect(diagnostics.text().len != 0);
    try std.testing.expectEqual(database_mod.Diagnostics.capacity >= diagnostics.text().len, true);

    var statement = try connection.prepare("SELECT 1", .{ .diagnostics = &diagnostics });
    defer statement.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
}

test "wrapper validation failures are allocation-free diagnostics" {
    var diagnostics = database_mod.Diagnostics{};
    try std.testing.expectError(
        error.InteriorNul,
        database_mod.Database.open(std.testing.allocator, .{
            .path = ":memory:\x00ignored",
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings(
        "database path is not valid UTF-8, contains an interior NUL, or could not be copied",
        diagnostics.text(),
    );
}

test "target-invalid and empty custom VFS choices fail before native construction" {
    var diagnostics = database_mod.Diagnostics{};
    try std.testing.expectError(
        error.InvalidVfsName,
        database_mod.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .vfs = .{ .custom = "" },
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings("custom VFS name must not be empty", diagnostics.text());

    const invalid: database_mod.Vfs = switch (@import("builtin").os.tag) {
        .linux => .experimental_win_iocp,
        else => .io_uring,
    };
    try std.testing.expectError(
        error.UnsupportedVfs,
        database_mod.Database.open(std.testing.allocator, .{
            .path = ":memory:",
            .vfs = invalid,
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings("selected VFS is not supported on this target", diagnostics.text());
}

test "database relocation with a live connection keeps child accounting stable" {
    var original = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    var connection = try original.connect(.{});
    var moved = original;
    original = undefined;
    defer moved.deinit();
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE relocation(value INTEGER)", &.{}, .{});
    try std.testing.expect(try connection.isAutocommit());
}

test "database and connection initialization clean every Zig OOM branch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, openAndConnect, .{});
}

fn openAndConnect(allocator: std.mem.Allocator) !void {
    var database = try database_mod.Database.open(allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
}

test "database creates independent connections concurrently" {
    var database = try database_mod.Database.open(std.heap.page_allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var context = ConcurrentContext{ .database = &database };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentConnectionWorker, .{&context});
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), context.failures.load(.acquire));
}

test "safe owner cleanup is idempotent on the same variable" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});

    var statement = try connection.prepare("SELECT 1", .{});
    statement.deinit();
    statement.deinit();

    var rows = try connection.query("SELECT 1", &.{}, .{});
    rows.deinit();
    rows.deinit();

    var transaction = try connection.begin(.deferred, .{});
    try transaction.rollback(null);
    transaction.deinit();
    transaction.deinit();

    try connection.close(null);
    try connection.close(null);
    connection.deinit();
    connection.deinit();
    database.deinit();
    database.deinit();
}

test "connection close is rejected until each exclusive child is quiescent" {
    var database = try database_mod.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var diagnostics = database_mod.Diagnostics{};

    var statement = try connection.prepare("SELECT 1", .{});
    try std.testing.expectError(error.InvalidState, connection.close(&diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "live statement") != null);
    statement.deinit();

    var rows = try connection.query("SELECT 1", &.{}, .{});
    try std.testing.expectError(error.InvalidState, connection.close(&diagnostics));
    rows.deinit();

    var transaction = try connection.begin(.deferred, .{});
    try std.testing.expectError(error.InvalidState, connection.close(&diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "active transaction") != null);
    try transaction.rollback(null);
    transaction.deinit();

    try connection.close(&diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
}

const ConcurrentContext = struct {
    database: *database_mod.Database,
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn concurrentConnectionWorker(context: *ConcurrentContext) void {
    var connection = context.database.connect(.{}) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
        return;
    };
    defer connection.deinit();
    _ = connection.exec("SELECT 1", &.{}, .{}) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
        return;
    };
}
