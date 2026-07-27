const std = @import("std");
const turso = @import("turso");

const Counters = struct {
    scalar_contexts_destroyed: usize = 0,
    aggregate_contexts_destroyed: usize = 0,
    aggregate_states_destroyed: usize = 0,
    collation_contexts_destroyed: usize = 0,
};

const ScalarContext = struct {
    counters: *Counters,
};

/// `args` and any text/blob slices nested in it are borrowed for this call.
/// Returning the borrowed value is safe because turso.zig copies text/blob
/// results into a destructor-owned result box before returning to native code.
fn echoOrRejectNegative(_: *ScalarContext, args: []const turso.Value) turso.CallbackError!turso.Value {
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] == .integer and args[0].integer < 0) return error.OutOfRange;
    return args[0];
}

fn destroyScalarContext(context: *ScalarContext) void {
    context.counters.scalar_contexts_destroyed += 1;
}

const AggregateContext = struct {
    counters: *Counters,
};

const SumState = struct {
    total: i64 = 0,
    counters: *Counters,
};

fn initSum(context: *AggregateContext) turso.CallbackError!SumState {
    return .{ .counters = context.counters };
}

fn stepSum(_: *AggregateContext, state: *SumState, args: []const turso.Value) turso.CallbackError!void {
    if (args.len != 1) return error.InvalidArguments;
    const value = args[0].asInteger() catch return error.InvalidArguments;
    state.total = std.math.add(i64, state.total, value) catch return error.OutOfRange;
}

fn finalSum(_: *AggregateContext, state: *SumState) turso.CallbackError!turso.Value {
    return .{ .integer = state.total };
}

fn destroyAggregateContext(context: *AggregateContext) void {
    context.counters.aggregate_contexts_destroyed += 1;
}

fn destroySumState(state: *SumState) void {
    state.counters.aggregate_states_destroyed += 1;
}

const CollationContext = struct {
    counters: *Counters,
};

fn reverseText(_: *CollationContext, left: []const u8, right: []const u8) turso.CollationOrder {
    // These UTF-8 slices are borrowed only for this callback and are never
    // stored in the context or returned to application code.
    return switch (std.mem.order(u8, left, right)) {
        .lt => .greater,
        .eq => .equal,
        .gt => .less,
    };
}

fn destroyCollationContext(context: *CollationContext) void {
    context.counters.collation_contexts_destroyed += 1;
}

pub fn main(init: std.process.Init) !void {
    var database = try turso.Database.open(init.gpa, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var counters = Counters{};
    try connection.registerScalarFunction("zig_echo", turso.ScalarFunctionOptions(ScalarContext){
        .context = .{ .counters = &counters },
        .callback = echoOrRejectNegative,
        .context_deinit = destroyScalarContext,
        .argc = 1,
        .deterministic = true,
    }, null);

    try connection.registerAggregateFunction("zig_sum", turso.AggregateFunctionOptions(AggregateContext, SumState){
        .context = .{ .counters = &counters },
        .init = initSum,
        .step = stepSum,
        .final = finalSum,
        .context_deinit = destroyAggregateContext,
        .state_deinit = destroySumState,
        .argc = 1,
    }, null);

    try connection.registerCollation("zig_reverse", turso.CollationOptions(CollationContext){
        .context = .{ .counters = &counters },
        .compare = reverseText,
        .context_deinit = destroyCollationContext,
    }, null);

    _ = try connection.exec("CREATE TABLE items(name TEXT, amount INTEGER)", &.{}, .{});
    _ = try connection.execBatch(
        "INSERT INTO items VALUES ('alpha', 2);" ++
            "INSERT INTO items VALUES ('gamma', 3);" ++
            "INSERT INTO items VALUES ('beta', 5);",
        .{},
    );

    var rows = try connection.query(
        "SELECT zig_echo(name) FROM items ORDER BY name COLLATE zig_reverse",
        &.{},
        .{},
    );
    while (try rows.next()) |row| {
        std.debug.print("{s}\n", .{try row.get([]const u8, 0)});
    }
    rows.deinit();

    const total = try queryInteger(&connection, "SELECT zig_sum(amount) FROM items");
    std.debug.print("sum: {d}\n", .{total});

    // Callback errors become ordinary Turso statement errors; no Zig error
    // union crosses the C boundary.
    var diagnostics = turso.Diagnostics{};
    var failing_rows = try connection.query(
        "SELECT zig_echo(-1)",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    const next_result = failing_rows.nextWithDiagnostics(&diagnostics);
    if (next_result) |_| {
        failing_rows.deinit();
        return error.ExpectedCallbackFailure;
    } else |err| switch (err) {
        error.TursoFailure => std.debug.print("callback rejected input: {s}\n", .{diagnostics.text()}),
        else => {
            failing_rows.deinit();
            return err;
        },
    }
    failing_rows.deinit();

    // Explicit unregister is the deterministic point at which each context is
    // released, once no prepared statement retains that registration.
    try connection.unregisterFunction("zig_echo", &diagnostics);
    try connection.unregisterFunction("zig_sum", &diagnostics);
    try connection.unregisterCollation("zig_reverse", &diagnostics);

    if (counters.scalar_contexts_destroyed != 1 or
        counters.aggregate_contexts_destroyed != 1 or
        counters.aggregate_states_destroyed != 1 or
        counters.collation_contexts_destroyed != 1)
    {
        return error.UnexpectedDestructorCount;
    }
}

fn queryInteger(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.ExpectedRow;
    return row.get(i64, 0);
}
