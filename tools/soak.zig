const std = @import("std");
const builtin = @import("builtin");
const turso = @import("turso");

const Defaults = struct {
    const iterations: usize = 128;
    const workers: usize = 8;
    const seed: u64 = 0x7475_7273_6f2e_7a69;
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const iterations = try parseArg(args.next(), Defaults.iterations, "iterations");
    const workers = try parseArg(args.next(), Defaults.workers, "workers");
    const seed = try parseArg(args.next(), Defaults.seed, "seed");
    if (args.next() != null) return error.TooManyArguments;
    if (iterations == 0 or workers == 0 or workers > 1024) return error.InvalidArgument;

    // Initialize native and Zig runtime worker pools before taking the resource
    // baseline. The soak is looking for per-operation growth, not one-time
    // process initialization retained until exit.
    try lifecycleSoak(init.gpa, 1);
    try fanoutStress(init.gpa, 1, workers, seed);
    try contentionStress(init, 2, workers, seed);
    try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);

    const resources_before = try linuxResourceCounts(init.io);
    std.debug.print("turso.zig soak iterations={d} workers={d} seed={d}\n", .{ iterations, workers, seed });
    try lifecycleSoak(init.gpa, iterations);
    try fanoutStress(init.gpa, iterations, workers, seed);
    try contentionStress(init, iterations, workers, seed);
    const resources_after = if (resources_before) |before|
        try settledLinuxResourceCounts(init.io, before)
    else
        null;
    if (resources_before != null and resources_after != null) {
        const before = resources_before.?;
        const after = resources_after.?;
        std.debug.print(
            "resources fd_before={d} fd_after={d} threads_before={d} threads_after={d}\n",
            .{ before.file_descriptors, after.file_descriptors, before.threads, after.threads },
        );
        if (after.file_descriptors > before.file_descriptors + 2 or after.threads > before.threads) {
            return error.ResourceGrowth;
        }
    }
    std.debug.print("turso.zig soak completed\n", .{});
}

const ResourceCounts = struct {
    file_descriptors: usize,
    threads: usize,
};

fn linuxResourceCounts(io: std.Io) !?ResourceCounts {
    if (builtin.os.tag != .linux) return null;
    return .{
        .file_descriptors = try directoryEntryCount(io, "/proc/self/fd"),
        .threads = try directoryEntryCount(io, "/proc/self/task"),
    };
}

fn settledLinuxResourceCounts(io: std.Io, before: ResourceCounts) !?ResourceCounts {
    if (builtin.os.tag != .linux) return null;

    var latest = (try linuxResourceCounts(io)).?;
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        if (latest.file_descriptors <= before.file_descriptors + 2 and
            latest.threads <= before.threads)
        {
            return latest;
        }
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
        latest = (try linuxResourceCounts(io)).?;
    }
    return latest;
}

fn directoryEntryCount(io: std.Io, path: []const u8) !usize {
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io) != null) count += 1;
    return count;
}

fn parseArg(maybe: ?[:0]const u8, default: anytype, comptime name: []const u8) !@TypeOf(default) {
    const bytes = maybe orelse return default;
    return std.fmt.parseUnsigned(@TypeOf(default), bytes, 0) catch {
        std.debug.print("invalid {s}: {s}\n", .{ name, bytes });
        return error.InvalidArgument;
    };
}

fn lifecycleSoak(allocator: std.mem.Allocator, iterations: usize) !void {
    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();
        _ = try connection.exec("CREATE TABLE lifecycle(value INTEGER, payload BLOB)", &.{}, .{});
        var statement = try connection.prepare("INSERT INTO lifecycle VALUES (?1, ?2)", .{});
        defer statement.deinit();
        try statement.bindParams(.{ @as(i64, @intCast(iteration)), turso.Blob{ .bytes = "payload" } }, null);
        _ = try statement.execute(null);
        try statement.finalize(null);
    }
}

const StressContext = struct {
    database: *turso.Database,
    iterations: usize,
    seed: u64,
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn fanoutStress(allocator: std.mem.Allocator, iterations: usize, workers: usize, seed: u64) !void {
    var database = try turso.Database.open(allocator, .{
        .path = "turso-zig-configurable-soak",
        .vfs = .memory,
    });
    defer database.deinit();
    var context = StressContext{
        .database = &database,
        .iterations = iterations,
        .seed = seed,
    };
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    for (threads, 0..) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, stressWorker, .{ &context, worker });
    }
    for (threads) |thread| thread.join();
    if (context.failures.load(.acquire) != 0) return error.StressFailure;
}

fn stressWorker(context: *StressContext, worker: usize) void {
    var connection = context.database.connect(.{}) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
        return;
    };
    defer connection.deinit();

    var iteration: usize = 0;
    while (iteration < context.iterations) : (iteration += 1) {
        stressIteration(&connection, worker, iteration, context.seed) catch {
            _ = context.failures.fetchAdd(1, .monotonic);
            return;
        };
    }
}

fn stressIteration(connection: *turso.Connection, worker: usize, iteration: usize, seed: u64) !void {
    const mixed = seed +% @as(u64, @intCast(worker *% 1_000_003)) +% @as(u64, @intCast(iteration));
    const expected: i64 = @intCast(mixed % 1_000_000_000);
    if ((mixed & 7) == 0) {
        var rows = try connection.query("SELECT ?1 UNION ALL SELECT ?1 + 1", &.{.{ .integer = expected }}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingRow;
        if (try row.get(i64, 0) != expected) return error.UnexpectedValue;
        try rows.cancel(null);
        return;
    }

    var rows = try connection.query("SELECT ?1 + 1", &.{.{ .integer = expected }}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (try row.get(i64, 0) != expected + 1) return error.UnexpectedValue;
    if ((try rows.next()) != null) return error.UnexpectedRow;
    try rows.finish(null);
}

const ContentionContext = struct {
    database: *turso.Database,
    iterations: usize,
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    successes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    busy: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn contentionStress(init: std.process.Init, iterations: usize, workers: usize, seed: u64) !void {
    var random_bytes: [8]u8 = undefined;
    init.io.random(&random_bytes);
    const random_name = std.fmt.bytesToHex(random_bytes, .lower);
    const directory_name = try std.fmt.allocPrint(init.gpa, ".turso-zig-soak-{x}-{s}", .{ seed, random_name });
    defer init.gpa.free(directory_name);
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(init.io, directory_name);
    var directory = try cwd.createDirPathOpen(init.io, directory_name, .{});
    defer {
        directory.close(init.io);
        cwd.deleteTree(init.io, directory_name) catch {};
    }
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try directory.realPath(init.io, &absolute_buffer);
    const database_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/contention.db",
        .{absolute_buffer[0..absolute_len]},
    );
    defer init.gpa.free(database_path);

    var database = try turso.Database.open(init.gpa, .{ .path = database_path });
    defer database.deinit();
    {
        var setup = try database.connect(.{});
        defer setup.deinit();
        _ = try setup.exec("CREATE TABLE writes(value INTEGER NOT NULL)", &.{}, .{});
    }

    var context = ContentionContext{
        .database = &database,
        .iterations = iterations,
    };
    var holder_connection = try database.connect(.{ .busy_timeout_ms = 0 });
    defer holder_connection.deinit();
    var holder = try holder_connection.begin(.immediate, .{});
    defer holder.deinit();
    const threads = try init.gpa.alloc(std.Thread, workers);
    defer init.gpa.free(threads);
    for (threads, 0..) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, contentionWorker, .{ &context, worker });
    }
    while (context.ready.load(.acquire) != workers) std.Thread.yield() catch {};
    context.start.store(true, .release);
    while (context.busy.load(.acquire) < workers) std.Thread.yield() catch {};
    try holder.rollback(null);
    context.release.store(true, .release);
    for (threads) |thread| thread.join();

    const successes = context.successes.load(.acquire);
    const busy = context.busy.load(.acquire);
    std.debug.print("contention successes={d} busy={d}\n", .{ successes, busy });
    if (context.failures.load(.acquire) != 0 or successes == 0 or busy == 0) {
        return error.ContentionStressFailure;
    }
    var verification = try database.connect(.{});
    defer verification.deinit();
    var rows = try verification.query("SELECT COUNT(*) FROM writes", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    if (try row.get(i64, 0) != @as(i64, @intCast(successes))) return error.UnexpectedWriteCount;
    try rows.finish(null);
}

fn contentionWorker(context: *ContentionContext, worker: usize) void {
    var connection = context.database.connect(.{ .busy_timeout_ms = 0 }) catch {
        _ = context.failures.fetchAdd(1, .monotonic);
        _ = context.ready.fetchAdd(1, .release);
        return;
    };
    defer connection.deinit();
    _ = context.ready.fetchAdd(1, .release);
    while (!context.start.load(.acquire)) std.Thread.yield() catch {};

    for (0..context.iterations) |iteration| {
        var transaction = connection.begin(.immediate, .{}) catch |err| switch (err) {
            error.Busy => {
                _ = context.busy.fetchAdd(1, .monotonic);
                while (!context.release.load(.acquire)) std.Thread.yield() catch {};
                continue;
            },
            else => {
                _ = context.failures.fetchAdd(1, .monotonic);
                return;
            },
        };
        defer transaction.deinit();
        _ = transaction.exec(
            "INSERT INTO writes VALUES (?1)",
            &.{.{ .integer = @intCast(worker *% context.iterations +% iteration) }},
            .{},
        ) catch {
            _ = context.failures.fetchAdd(1, .monotonic);
            return;
        };
        for (0..4) |_| std.Thread.yield() catch {};
        transaction.commit(null) catch {
            _ = context.failures.fetchAdd(1, .monotonic);
            return;
        };
        _ = context.successes.fetchAdd(1, .monotonic);
    }
}
