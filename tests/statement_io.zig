const std = @import("std");
const connection_mod = @import("connection");

const FixtureStats = extern struct {
    prepare_calls: u32,
    execute_calls: u32,
    step_calls: u32,
    run_io_calls: u32,
    reset_calls: u32,
    finalize_calls: u32,
    statement_deinit_calls: u32,
    connection_deinit_calls: u32,
    string_deinit_calls: u32,
};

extern fn statement_io_fixture_reset(
    execute_io_turns: u32,
    step_io_turns: u32,
    finalize_io_turns: u32,
    fail_run_io_call: u32,
) void;
extern fn statement_io_fixture_fail_reset_call(call: u32) void;
extern fn statement_io_fixture_connection() *anyopaque;
extern fn statement_io_fixture_stats() FixtureStats;

test "default connection policy rejects IO without running it" {
    statement_io_fixture_reset(2, 0, 0, 0);
    var owners = std.atomic.Value(usize).init(1);
    var connection = try connection_mod.init(
        std.testing.allocator,
        @ptrCast(statement_io_fixture_connection()),
        &owners,
    );

    var statement = try connection.prepare("fixture execute", .{});
    try std.testing.expectError(error.Unsupported, statement.execute(null));
    try statement.reset(null);
    statement.deinit();
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.execute_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.run_io_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.reset_calls);
    try expectExactCleanup(stats, owners.load(.acquire));
}

test "inline policy drives one and multiple execute IO turns" {
    for ([_]u32{ 1, 3 }) |turns| {
        statement_io_fixture_reset(turns, 0, 0, 0);
        var owners = std.atomic.Value(usize).init(1);
        var connection = try initInline(&owners);

        var statement = try connection.prepare("fixture execute", .{});
        try std.testing.expectEqual(@as(u64, 7), try statement.execute(null));
        try statement.finish(null);
        statement.deinit();
        connection.deinit();

        const stats = statement_io_fixture_stats();
        try std.testing.expectEqual(turns + 1, stats.execute_calls);
        try std.testing.expectEqual(turns, stats.run_io_calls);
        try expectExactCleanup(stats, owners.load(.acquire));
    }
}

test "inline policy drives one and multiple row-step IO turns" {
    for ([_]u32{ 1, 3 }) |turns| {
        statement_io_fixture_reset(0, turns, 0, 0);
        var owners = std.atomic.Value(usize).init(1);
        var connection = try initInline(&owners);

        var statement = try connection.prepare("fixture rows", .{});
        var rows = try statement.intoRows(null);
        try std.testing.expect((try rows.next()) != null);
        try std.testing.expect((try rows.next()) == null);
        try rows.finish(null);
        rows.deinit();
        connection.deinit();

        const stats = statement_io_fixture_stats();
        try std.testing.expectEqual(turns + 2, stats.step_calls);
        try std.testing.expectEqual(turns, stats.run_io_calls);
        try expectExactCleanup(stats, owners.load(.acquire));
    }
}

test "run_io failure preserves mapped error and native diagnostics" {
    statement_io_fixture_reset(1, 0, 0, 1);
    var owners = std.atomic.Value(usize).init(1);
    var connection = try initInline(&owners);
    var diagnostics = connection_mod.Diagnostics{};

    var statement = try connection.prepare("fixture run_io failure", .{});
    try std.testing.expectError(error.Io, statement.execute(&diagnostics));
    try std.testing.expectEqualStrings("fixture run_io failure", diagnostics.text());
    statement.deinit();
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.run_io_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.string_deinit_calls);
    try expectExactCleanup(stats, owners.load(.acquire));
}

test "inline finalize reaches terminal state after multiple IO turns" {
    statement_io_fixture_reset(0, 0, 3, 0);
    var owners = std.atomic.Value(usize).init(1);
    var connection = try initInline(&owners);

    var statement = try connection.prepare("fixture finalize", .{});
    try statement.finish(null);
    statement.deinit();
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 4), stats.finalize_calls);
    try std.testing.expectEqual(@as(u32, 3), stats.run_io_calls);
    try expectExactCleanup(stats, owners.load(.acquire));
}

test "rows cancellation aborts pending IO without driving it" {
    statement_io_fixture_reset(0, 2, 0, 0);
    var owners = std.atomic.Value(usize).init(1);
    var connection = try initInline(&owners);

    var statement = try connection.prepare("fixture cancel", .{});
    var rows = try statement.intoRows(null);
    try rows.cancel(null);
    rows.deinit();
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.reset_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.run_io_calls);
    try expectExactCleanup(stats, owners.load(.acquire));
}

test "prepared rows reset failure releases the active slot without false reuse" {
    statement_io_fixture_reset(0, 0, 0, 0);
    statement_io_fixture_fail_reset_call(1);
    var owners = std.atomic.Value(usize).init(1);
    var connection = try initInline(&owners);
    var diagnostics = connection_mod.Diagnostics{};

    var statement = try connection.prepare("fixture reset failure", .{});
    var rows = try statement.query(&.{}, null);
    try std.testing.expectError(error.Io, rows.cancel(&diagnostics));
    try std.testing.expectEqualStrings("fixture reset failure", diagnostics.text());
    try std.testing.expectError(error.InvalidState, statement.query(&.{}, null));

    var independent = try connection.prepare("fixture independent", .{});
    independent.deinit();
    statement.deinit();
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.reset_calls);
    try std.testing.expectEqual(@as(u32, 2), stats.prepare_calls);
    try std.testing.expectEqual(@as(u32, 2), stats.statement_deinit_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.connection_deinit_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.string_deinit_calls);
    try std.testing.expectEqual(@as(usize, 0), owners.load(.acquire));
}

test "statement-state allocation failure releases the native handle" {
    statement_io_fixture_reset(0, 0, 0, 0);
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var owners = std.atomic.Value(usize).init(1);
    var connection = try connection_mod.init(
        allocator,
        @ptrCast(statement_io_fixture_connection()),
        &owners,
    );

    // The SQL copy succeeds; the following heap-stable statement-state
    // allocation fails after native prepare has returned a handle.
    allocator_probe.fail_index = allocator_probe.alloc_index + 1;
    try std.testing.expectError(
        error.OutOfMemory,
        connection.prepare("fixture allocation failure", .{}),
    );
    connection.deinit();

    const stats = statement_io_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.prepare_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.statement_deinit_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.connection_deinit_calls);
    try std.testing.expectEqual(@as(usize, 0), owners.load(.acquire));
    try std.testing.expect(allocator_probe.has_induced_failure);
}

fn initInline(owners: *std.atomic.Value(usize)) !connection_mod.Connection {
    return connection_mod.initWithStatementIoPolicy(
        std.testing.allocator,
        @ptrCast(statement_io_fixture_connection()),
        owners,
        .drive_io_inline,
    );
}

fn expectExactCleanup(stats: FixtureStats, owner_count: usize) !void {
    try std.testing.expectEqual(@as(u32, 1), stats.prepare_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.statement_deinit_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.connection_deinit_calls);
    try std.testing.expectEqual(@as(usize, 0), owner_count);
}
