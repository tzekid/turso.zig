const std = @import("std");
const turso = @import("turso");

const CallbackError = turso.Connection.CallbackError;

fn queryInt(connection: *turso.Connection, sql: []const u8) !i64 {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    return row.get(i64, 0);
}

fn queryText(connection: *turso.Connection, sql: []const u8) !turso.OwnedValue {
    var rows = try connection.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    return (try row.value(0)).toOwned(std.testing.allocator);
}

const ScalarCounters = struct {
    context_drops: usize = 0,
    calls: usize = 0,
};

const ScalarContext = struct {
    factor: i64,
    counters: *ScalarCounters,
};

fn scale(context: *ScalarContext, args: []const turso.Value) CallbackError!turso.Value {
    context.counters.calls += 1;
    if (args.len != 1) return error.InvalidArguments;
    const number = args[0].asInteger() catch return error.InvalidArguments;
    return .{ .integer = std.math.mul(i64, number, context.factor) catch return error.OutOfRange };
}

fn echo(_: *ScalarContext, args: []const turso.Value) CallbackError!turso.Value {
    if (args.len != 1) return error.InvalidArguments;
    return args[0];
}

fn dropScalarContext(context: *ScalarContext) void {
    context.counters.context_drops += 1;
}

test "managed scalar values errors replacement and unregister have exact ownership" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var counters = ScalarCounters{};
    try connection.registerScalarFunction("zig_scale", turso.Connection.ScalarFunctionOptions(ScalarContext){
        .context = .{ .factor = 2, .counters = &counters },
        .callback = scale,
        .context_deinit = dropScalarContext,
        .argc = 1,
        .deterministic = true,
    }, null);
    try std.testing.expectEqual(@as(i64, 12), try queryInt(&connection, "SELECT zig_scale(6)"));

    // Replacement transfers ownership of the new context and releases the old
    // registration once no prepared statement retains it.
    try connection.registerScalarFunction("zig_scale", turso.Connection.ScalarFunctionOptions(ScalarContext){
        .context = .{ .factor = 3, .counters = &counters },
        .callback = scale,
        .context_deinit = dropScalarContext,
        .argc = 1,
    }, null);
    try std.testing.expectEqual(@as(usize, 1), counters.context_drops);
    try std.testing.expectEqual(@as(i64, 18), try queryInt(&connection, "SELECT zig_scale(6)"));

    var diagnostics = turso.Diagnostics{};
    var bad_rows = try connection.query("SELECT zig_scale('not an integer')", &.{}, .{});
    try std.testing.expectError(error.TursoFailure, bad_rows.next());
    bad_rows.deinit();

    // Returning a borrowed callback argument is safe: the trampoline copies
    // text/blob payloads into destructor-owned result boxes before C sees them.
    try connection.registerScalarFunction("zig_echo", turso.Connection.ScalarFunctionOptions(ScalarContext){
        .context = .{ .factor = 0, .counters = &counters },
        .callback = echo,
        .context_deinit = dropScalarContext,
        .argc = 1,
    }, &diagnostics);
    var text = try queryText(&connection, "SELECT zig_echo('hello')");
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", try text.get([]const u8));
    var blob = try queryText(&connection, "SELECT hex(zig_echo(X'00FF10'))");
    defer blob.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("00FF10", try blob.get([]const u8));

    try connection.unregisterFunction("zig_scale", null);
    try std.testing.expectEqual(@as(usize, 2), counters.context_drops);
    try connection.unregisterFunction("zig_echo", null);
    try std.testing.expectEqual(@as(usize, 3), counters.context_drops);
    try std.testing.expectError(error.TursoFailure, connection.unregisterFunction("zig_echo", &diagnostics));
    try std.testing.expect(diagnostics.text().len != 0);
}

test "registration context is released on validation failure and connection teardown" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});

    var counters = ScalarCounters{};
    try std.testing.expectError(error.InvalidState, connection.registerScalarFunction(
        "invalid_arity",
        turso.Connection.ScalarFunctionOptions(ScalarContext){
            .context = .{ .factor = 1, .counters = &counters },
            .callback = scale,
            .context_deinit = dropScalarContext,
            .argc = -2,
        },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), counters.context_drops);

    try std.testing.expectError(error.InteriorNul, connection.registerScalarFunction(
        "invalid\x00name",
        turso.Connection.ScalarFunctionOptions(ScalarContext){
            .context = .{ .factor = 1, .counters = &counters },
            .callback = scale,
            .context_deinit = dropScalarContext,
            .argc = 1,
        },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 2), counters.context_drops);

    try connection.registerScalarFunction("connection_owned", turso.Connection.ScalarFunctionOptions(ScalarContext){
        .context = .{ .factor = 1, .counters = &counters },
        .callback = scale,
        .context_deinit = dropScalarContext,
        .argc = 1,
    }, null);
    connection.deinit();
    try std.testing.expectEqual(@as(usize, 3), counters.context_drops);
}

const AggregateCounters = struct {
    contexts_dropped: usize = 0,
    states_initialized: usize = 0,
    states_dropped: usize = 0,
    steps: usize = 0,
};

const AggregateContext = struct {
    counters: *AggregateCounters,
    fail_negative: bool = false,
    fail_final: bool = false,
};

const SumState = struct {
    sum: i64 = 0,
    counters: *AggregateCounters,
};

fn initSum(context: *AggregateContext) CallbackError!SumState {
    context.counters.states_initialized += 1;
    return .{ .counters = context.counters };
}

fn initSumFailure(_: *AggregateContext) CallbackError!SumState {
    return error.Custom;
}

fn stepSum(context: *AggregateContext, state: *SumState, args: []const turso.Value) CallbackError!void {
    context.counters.steps += 1;
    if (args.len != 1) return error.InvalidArguments;
    const number = args[0].asInteger() catch return error.InvalidArguments;
    if (context.fail_negative and number < 0) return error.ConstraintViolation;
    state.sum = std.math.add(i64, state.sum, number) catch return error.OutOfRange;
}

fn finalSum(context: *AggregateContext, state: *SumState) CallbackError!turso.Value {
    if (context.fail_final) return error.Custom;
    return .{ .integer = state.sum };
}

fn dropAggregateContext(context: *AggregateContext) void {
    context.counters.contexts_dropped += 1;
}

fn dropSumState(state: *SumState) void {
    state.counters.states_dropped += 1;
}

fn sumOptions(context: AggregateContext) turso.Connection.AggregateFunctionOptions(AggregateContext, SumState) {
    return .{
        .context = context,
        .init = initSum,
        .step = stepSum,
        .final = finalSum,
        .context_deinit = dropAggregateContext,
        .state_deinit = dropSumState,
        .argc = 1,
    };
}

test "managed aggregate owns every group state through success and callback errors" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE numbers(group_id INTEGER, value INTEGER)", &.{}, .{});
    _ = try connection.execBatch(
        "INSERT INTO numbers VALUES (1, 2); INSERT INTO numbers VALUES (1, 3);" ++
            "INSERT INTO numbers VALUES (2, 5); INSERT INTO numbers VALUES (2, 7);",
        .{},
    );

    var counters = AggregateCounters{};
    try connection.registerAggregateFunction("zig_sum", sumOptions(.{ .counters = &counters }), null);
    var rows = try connection.query(
        "SELECT group_id, zig_sum(value) FROM numbers GROUP BY group_id ORDER BY group_id",
        &.{},
        .{},
    );
    {
        const row = (try rows.next()).?;
        try std.testing.expectEqual(@as(i64, 1), try row.get(i64, 0));
        try std.testing.expectEqual(@as(i64, 5), try row.get(i64, 1));
    }
    {
        const row = (try rows.next()).?;
        try std.testing.expectEqual(@as(i64, 2), try row.get(i64, 0));
        try std.testing.expectEqual(@as(i64, 12), try row.get(i64, 1));
    }
    try std.testing.expect((try rows.next()) == null);
    rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), counters.states_initialized);
    try std.testing.expectEqual(counters.states_initialized, counters.states_dropped);

    // Replacement releases the registration context but never aliases it with
    // per-group state ownership.
    try connection.registerAggregateFunction("zig_sum", sumOptions(.{ .counters = &counters }), null);
    try std.testing.expectEqual(@as(usize, 1), counters.contexts_dropped);

    try connection.registerAggregateFunction("zig_step_error", sumOptions(.{
        .counters = &counters,
        .fail_negative = true,
    }), null);
    var step_error_rows = try connection.query(
        "SELECT zig_step_error(value) FROM (SELECT 1 AS value UNION ALL SELECT -1)",
        &.{},
        .{},
    );
    try std.testing.expectError(error.TursoFailure, step_error_rows.next());
    step_error_rows.deinit();
    try std.testing.expectEqual(counters.states_initialized, counters.states_dropped);

    try connection.registerAggregateFunction("zig_final_error", sumOptions(.{
        .counters = &counters,
        .fail_final = true,
    }), null);
    var final_error_rows = try connection.query("SELECT zig_final_error(value) FROM numbers", &.{}, .{});
    try std.testing.expectError(error.TursoFailure, final_error_rows.next());
    final_error_rows.deinit();
    try std.testing.expectEqual(counters.states_initialized, counters.states_dropped);

    try connection.registerAggregateFunction(
        "zig_init_error",
        turso.Connection.AggregateFunctionOptions(AggregateContext, SumState){
            .context = .{ .counters = &counters },
            .init = initSumFailure,
            .step = stepSum,
            .final = finalSum,
            .context_deinit = dropAggregateContext,
            .state_deinit = dropSumState,
            .argc = 1,
        },
        null,
    );
    var init_error_rows = try connection.query("SELECT zig_init_error(value) FROM numbers", &.{}, .{});
    try std.testing.expectError(error.TursoFailure, init_error_rows.next());
    init_error_rows.deinit();
    try std.testing.expectEqual(counters.states_initialized, counters.states_dropped);

    // Empty-input finalization still initializes and releases exactly one state.
    try std.testing.expectEqual(@as(i64, 0), try queryInt(&connection, "SELECT zig_sum(value) FROM numbers WHERE 0"));
    try std.testing.expectEqual(counters.states_initialized, counters.states_dropped);

    try connection.unregisterFunction("zig_sum", null);
    try connection.unregisterFunction("zig_step_error", null);
    try connection.unregisterFunction("zig_final_error", null);
    try connection.unregisterFunction("zig_init_error", null);
    try std.testing.expectEqual(@as(usize, 5), counters.contexts_dropped);
}

const CollationCounters = struct { drops: usize = 0 };
const CollationContext = struct {
    reverse: bool,
    counters: *CollationCounters,
};

fn lexical(context: *CollationContext, left: []const u8, right: []const u8) turso.Connection.CollationOrder {
    const order = std.mem.order(u8, left, right);
    const result: turso.Connection.CollationOrder = switch (order) {
        .lt => .less,
        .eq => .equal,
        .gt => .greater,
    };
    if (!context.reverse) return result;
    return switch (result) {
        .less => .greater,
        .equal => .equal,
        .greater => .less,
    };
}

fn dropCollation(context: *CollationContext) void {
    context.counters.drops += 1;
}

fn expectOrdering(connection: *turso.Connection, expected: []const []const u8) !void {
    var rows = try connection.query("SELECT value FROM words ORDER BY value COLLATE zig_order", &.{}, .{});
    defer rows.deinit();
    for (expected) |text| {
        const row = (try rows.next()).?;
        try std.testing.expectEqualStrings(text, try row.get([]const u8, 0));
    }
    try std.testing.expect((try rows.next()) == null);
}

test "managed collation ordering replacement and unregister release contexts" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE words(value TEXT)", &.{}, .{});
    _ = try connection.execBatch("INSERT INTO words VALUES ('b'); INSERT INTO words VALUES ('a'); INSERT INTO words VALUES ('c');", .{});

    var counters = CollationCounters{};
    try connection.registerCollation("zig_order", turso.Connection.CollationOptions(CollationContext){
        .context = .{ .reverse = true, .counters = &counters },
        .compare = lexical,
        .context_deinit = dropCollation,
    }, null);
    try expectOrdering(&connection, &.{ "c", "b", "a" });

    try connection.registerCollation("zig_order", turso.Connection.CollationOptions(CollationContext){
        .context = .{ .reverse = false, .counters = &counters },
        .compare = lexical,
        .context_deinit = dropCollation,
    }, null);
    try std.testing.expectEqual(@as(usize, 1), counters.drops);
    try expectOrdering(&connection, &.{ "a", "b", "c" });
    try connection.unregisterCollation("zig_order", null);
    try std.testing.expectEqual(@as(usize, 2), counters.drops);
}

test "SQL extension loading is opt-in and direct loading reports failures" {
    var diagnostics = turso.Diagnostics{};
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    try std.testing.expectError(
        error.TursoFailure,
        connection.exec("SELECT load_extension('definitely_missing_turso_zig_extension')", &.{}, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "disabled") != null);

    try connection.enableLoadExtension(true, &diagnostics);
    try std.testing.expectError(
        error.TursoFailure,
        connection.exec("SELECT load_extension('definitely_missing_turso_zig_extension')", &.{}, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "disabled") == null);
    try connection.enableLoadExtension(false, null);

    try std.testing.expectError(
        error.TursoFailure,
        connection.loadExtension("definitely_missing_turso_zig_extension", &diagnostics),
    );
    try std.testing.expect(diagnostics.text().len != 0);
    try std.testing.expectError(error.InteriorNul, connection.loadExtension("bad\x00path", &diagnostics));
}

const AllocationContext = struct {
    drops: *usize,
};

fn allocationEcho(_: *AllocationContext, args: []const turso.Value) CallbackError!turso.Value {
    if (args.len != 1) return error.InvalidArguments;
    return args[0];
}

fn allocationText(_: *AllocationContext, args: []const turso.Value) CallbackError!turso.Value {
    if (args.len != 1) return error.InvalidArguments;
    _ = args[0];
    return .{ .text = "callback result" };
}

fn allocationEmptyText(_: *AllocationContext, args: []const turso.Value) CallbackError!turso.Value {
    if (args.len != 0) return error.InvalidArguments;
    return .{ .text = "" };
}

fn allocationEmptyBlob(_: *AllocationContext, args: []const turso.Value) CallbackError!turso.Value {
    if (args.len != 0) return error.InvalidArguments;
    return .{ .blob = &.{} };
}

fn dropAllocationContext(context: *AllocationContext) void {
    context.drops.* += 1;
}

test "registration allocator failures release moved contexts exactly once" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});

    var drops: usize = 0;
    allocator_probe.fail_index = allocator_probe.alloc_index;
    try std.testing.expectError(error.OutOfMemory, connection.registerScalarFunction(
        "box_allocation_failure",
        turso.Connection.ScalarFunctionOptions(AllocationContext){
            .context = .{ .drops = &drops },
            .callback = allocationEcho,
            .context_deinit = dropAllocationContext,
            .argc = 1,
        },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), drops);

    // Let the context box succeed and fail the following copied-name allocation.
    allocator_probe.fail_index = allocator_probe.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, connection.registerScalarFunction(
        "name_allocation_failure",
        turso.Connection.ScalarFunctionOptions(AllocationContext){
            .context = .{ .drops = &drops },
            .callback = allocationEcho,
            .context_deinit = dropAllocationContext,
            .argc = 1,
        },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 2), drops);

    allocator_probe.fail_index = std.math.maxInt(usize);
    connection.deinit();
    database.deinit();
    try std.testing.expectEqual(allocator_probe.allocated_bytes, allocator_probe.freed_bytes);
}

test "callback argument and result allocation failures return errors without leaks" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});
    var drops: usize = 0;

    try connection.registerScalarFunction(
        "allocation_text",
        turso.Connection.ScalarFunctionOptions(AllocationContext){
            .context = .{ .drops = &drops },
            .callback = allocationText,
            .context_deinit = dropAllocationContext,
            .argc = 1,
        },
        null,
    );

    // Preparing is complete before failure injection, so the next Zig
    // allocation is callback argument decoding rather than SQL setup.
    var args_failure = try connection.query("SELECT allocation_text(1)", &.{}, .{});
    allocator_probe.fail_index = allocator_probe.alloc_index;
    try std.testing.expectError(error.TursoFailure, args_failure.next());
    allocator_probe.fail_index = std.math.maxInt(usize);
    args_failure.deinit();

    // One callback allocation succeeds for args, then TextBox allocation fails.
    var result_failure = try connection.query("SELECT allocation_text(1)", &.{}, .{});
    allocator_probe.fail_index = allocator_probe.alloc_index + 1;
    try std.testing.expectError(error.TursoFailure, result_failure.next());
    allocator_probe.fail_index = std.math.maxInt(usize);
    result_failure.deinit();

    try connection.registerScalarFunction(
        "allocation_empty_text",
        turso.Connection.ScalarFunctionOptions(AllocationContext){
            .context = .{ .drops = &drops },
            .callback = allocationEmptyText,
            .context_deinit = dropAllocationContext,
            .argc = 0,
        },
        null,
    );
    try connection.registerScalarFunction(
        "allocation_empty_blob",
        turso.Connection.ScalarFunctionOptions(AllocationContext){
            .context = .{ .drops = &drops },
            .callback = allocationEmptyBlob,
            .context_deinit = dropAllocationContext,
            .argc = 0,
        },
        null,
    );
    var empty_rows = try connection.query(
        "SELECT length(allocation_empty_text()), length(allocation_empty_blob())",
        &.{},
        .{},
    );
    const empty_row = (try empty_rows.next()).?;
    try std.testing.expectEqual(@as(i64, 0), try empty_row.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 0), try empty_row.get(i64, 1));
    try std.testing.expect((try empty_rows.next()) == null);
    empty_rows.deinit();

    connection.deinit();
    database.deinit();
    try std.testing.expectEqual(@as(usize, 3), drops);
    try std.testing.expectEqual(allocator_probe.allocated_bytes, allocator_probe.freed_bytes);
}

test "aggregate state allocation failure is leak-free for stepped and zero-row groups" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});

    var counters = AggregateCounters{};
    try connection.registerAggregateFunction(
        "zig_oom_sum",
        sumOptions(.{ .counters = &counters }),
        null,
    );

    var stepped = try connection.query(
        "SELECT zig_oom_sum(value) FROM (SELECT 1 AS value)",
        &.{},
        .{},
    );
    allocator_probe.fail_index = allocator_probe.alloc_index;
    try std.testing.expectError(error.TursoFailure, stepped.next());
    allocator_probe.fail_index = std.math.maxInt(usize);
    stepped.deinit();

    var zero_rows = try connection.query(
        "SELECT zig_oom_sum(value) FROM (SELECT 1 AS value WHERE 0)",
        &.{},
        .{},
    );
    allocator_probe.fail_index = allocator_probe.alloc_index;
    try std.testing.expectError(error.TursoFailure, zero_rows.next());
    allocator_probe.fail_index = std.math.maxInt(usize);
    zero_rows.deinit();

    try std.testing.expectEqual(@as(usize, 0), counters.states_initialized);
    try std.testing.expectEqual(@as(usize, 0), counters.states_dropped);
    connection.deinit();
    database.deinit();
    try std.testing.expectEqual(@as(usize, 1), counters.contexts_dropped);
    try std.testing.expectEqual(allocator_probe.allocated_bytes, allocator_probe.freed_bytes);
}

test "an aggregate error destroys sibling aggregate states" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});

    var survivor = AggregateCounters{};
    var failing = AggregateCounters{};
    try connection.registerAggregateFunction(
        "zig_survivor",
        sumOptions(.{ .counters = &survivor }),
        null,
    );
    try connection.registerAggregateFunction(
        "zig_failing_sibling",
        sumOptions(.{ .counters = &failing, .fail_negative = true }),
        null,
    );

    var rows = try connection.query(
        "SELECT zig_survivor(value), zig_failing_sibling(value) " ++
            "FROM (SELECT 1 AS value UNION ALL SELECT -1)",
        &.{},
        .{},
    );
    try std.testing.expectError(error.TursoFailure, rows.next());
    rows.deinit();

    connection.deinit();
    database.deinit();
    try std.testing.expectEqual(survivor.states_initialized, survivor.states_dropped);
    try std.testing.expectEqual(failing.states_initialized, failing.states_dropped);
    try std.testing.expectEqual(allocator_probe.allocated_bytes, allocator_probe.freed_bytes);
}

test "explicit reset sweeps sibling aggregate states after an error" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    var connection = try database.connect(.{});

    var survivor = AggregateCounters{};
    var failing = AggregateCounters{};
    try connection.registerAggregateFunction(
        "zig_reset_survivor",
        sumOptions(.{ .counters = &survivor }),
        null,
    );
    try connection.registerAggregateFunction(
        "zig_reset_failure",
        sumOptions(.{ .counters = &failing, .fail_negative = true }),
        null,
    );

    var statement = try connection.prepare(
        "SELECT zig_reset_survivor(value), zig_reset_failure(value) " ++
            "FROM (SELECT 1 AS value UNION ALL SELECT -1)",
        .{},
    );
    try std.testing.expectError(error.TursoFailure, statement.execute(null));
    try statement.reset(null);
    try std.testing.expectEqual(survivor.states_initialized, survivor.states_dropped);
    try std.testing.expectEqual(failing.states_initialized, failing.states_dropped);

    statement.deinit();
    connection.deinit();
    database.deinit();
    try std.testing.expectEqual(allocator_probe.allocated_bytes, allocator_probe.freed_bytes);
}
