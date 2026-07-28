const std = @import("std");
const sync = @import("turso_sync");

const FixtureStats = extern struct {
    databases_created: u32,
    databases_deinited: u32,
    operations_created: u32,
    operations_deinited: u32,
    items_created: u32,
    items_deinited: u32,
    changes_created: u32,
    changes_deinited: u32,
    changes_consumed: u32,
    connections_created: u32,
    connections_deinited: u32,
    strings_deinited: u32,
    callbacks_stepped: u32,
    status_calls: u32,
    buffer_calls: u32,
    done_calls: u32,
    poison_calls: u32,
    push_calls: u32,
    wait_calls: u32,
    apply_calls: u32,
    workflow_sequence_len: u32,
    workflow_sequence: [3]u32,
};

extern fn sync_lifecycle_fixture_reset() void;
extern fn sync_lifecycle_fixture_set(
    constructor: c_int,
    operation_failure: c_int,
    poll_failure: c_int,
    mismatch: c_int,
    no_changes: c_int,
    fail_apply: c_int,
    needs_io: c_int,
    request_kind: c_int,
    bad_headers: c_int,
) void;
extern fn sync_lifecycle_fixture_stats() FixtureStats;

const NoIoTransport = struct {
    pub fn request(
        _: *NoIoTransport,
        _: sync.TransportHttpRequest,
        _: *sync.ResponseWriter,
    ) error{UnexpectedIo}!void {
        return error.UnexpectedIo;
    }

    pub fn readFile(
        _: *NoIoTransport,
        _: []const u8,
        _: *sync.BufferWriter,
    ) error{UnexpectedIo}!void {
        return error.UnexpectedIo;
    }

    pub fn writeFileAtomically(
        _: *NoIoTransport,
        _: []const u8,
        _: []const u8,
    ) error{UnexpectedIo}!void {
        return error.UnexpectedIo;
    }
};

test "curated sync API exposes checked close and infallible cleanup only" {
    comptime {
        requireVoidDeinit(sync.SyncDatabase);
        requireVoidDeinit(sync.Operation(void));
        requireVoidDeinit(sync.IoItem);
        requireVoidDeinit(sync.Changes);
    }
    try std.testing.expect(!@hasDecl(sync.config, "NativeConfig"));
    try std.testing.expect(!@hasDecl(sync.operation, "init"));
    try std.testing.expect(!@hasDecl(sync.operation, "Recovery"));
    try std.testing.expect(!@hasDecl(sync.io, "take"));
    try std.testing.expect(!@hasDecl(sync.Changes, "takeForApply"));
    try std.testing.expect(!@hasField(sync.Operation(void), "pending_item"));
    try std.testing.expect(!@hasField(sync.Operation(void), "pending_poison"));
    try std.testing.expect(@hasDecl(sync, "run"));
    try std.testing.expect(@hasDecl(sync, "runVoid"));
    try std.testing.expect(@hasDecl(sync, "runConnection"));
    try std.testing.expect(@hasDecl(sync, "pull"));
    try std.testing.expect(@hasDecl(sync, "sync"));
}

test "constructor frees partial handles and native messages" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(1, 0, 0, 0, 0, 0, 0, 1, 0);
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(
        error.TursoFailure,
        openDatabase(std.testing.allocator, &diagnostics),
    );
    try std.testing.expectEqualStrings("constructor secret-redacted failure", diagnostics.text());
    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), fixture.databases_created);
    try std.testing.expectEqual(@as(u32, 1), fixture.databases_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.strings_deinited);
}

test "every allocation failure after native construction is balanced" {
    sync_lifecycle_fixture_reset();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, openAndClose, .{});
    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expect(fixture.databases_created != 0);
    try std.testing.expectEqual(fixture.databases_created, fixture.databases_deinited);
}

test "operation construction is serialized and partial failures are released" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.create(null);
    try std.testing.expectError(error.InvalidState, database.stats(null));
    try std.testing.expectError(error.InvalidState, database.close(null));
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    try operation.finish(null);
    try closeAndDeinit(&operation);

    sync_lifecycle_fixture_set(0, 1, 0, 0, 0, 0, 0, 1, 0);
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.TursoFailure, database.open(&diagnostics));
    try std.testing.expectEqualStrings("operation constructor failure", diagnostics.text());
    try closeAndDeinit(&database);

    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.strings_deinited);
}

test "void operation and typed mismatch enforce exact extraction" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.checkpoint(null);
    try std.testing.expectError(error.InvalidState, operation.finish(null));
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.InvalidState, operation.close(&diagnostics));
    try std.testing.expectEqualStrings("sync operation must finish or fail before close", diagnostics.text());
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    try operation.finish(null);
    try std.testing.expectError(error.InvalidState, operation.finish(null));
    try closeAndDeinit(&operation);
    operation.deinit();

    sync_lifecycle_fixture_set(0, 0, 0, 1, 0, 0, 0, 1, 0);
    var mismatch = try database.push(null);
    try std.testing.expectEqual(sync.Poll.done, try mismatch.poll(null));
    try std.testing.expectError(error.TypeMismatch, mismatch.finish(null));
    try closeAndDeinit(&mismatch);
    try closeAndDeinit(&database);
}

test "connection extraction adopts native ownership and database child count" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.connect(null);
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    var connection = try operation.finish(null);
    try closeAndDeinit(&operation);

    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.InvalidState, database.close(&diagnostics));
    try std.testing.expectEqualStrings("sync database cannot close with live connections", diagnostics.text());
    connection.deinit();
    try database.close(&diagnostics);
    database.deinit();
    database.deinit();
    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), fixture.connections_created);
    try std.testing.expectEqual(@as(u32, 1), fixture.connections_deinited);
}

test "stats revision is copied before operation teardown" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.stats(null);
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    var stats = try operation.finish(null);
    try std.testing.expectEqualStrings("rev-123", stats.revision);
    try closeAndDeinit(&operation);
    try std.testing.expectEqualStrings("rev-123", stats.revision);
    try std.testing.expectEqual(@as(i64, 9), stats.cdc_operations);
    stats.deinit();
    try closeAndDeinit(&database);
}

test "stats revision OOM leaves operation terminal and database recoverable" {
    sync_lifecycle_fixture_reset();
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try openDatabase(allocator, null);
    var operation = try database.stats(null);
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));

    allocator_probe.fail_index = allocator_probe.alloc_index;
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.OutOfMemory, operation.finish(&diagnostics));
    try std.testing.expectEqualStrings("sync stats revision could not be copied", diagnostics.text());
    try std.testing.expect(allocator_probe.has_induced_failure);
    try closeAndDeinit(&operation);

    var next = try database.checkpoint(null);
    try std.testing.expectEqual(sync.Poll.done, try next.poll(null));
    try next.finish(null);
    try closeAndDeinit(&next);
    try closeAndDeinit(&database);

    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 2), fixture.operations_created);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
}

test "null changes are represented without an owner" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(0, 0, 0, 0, 1, 0, 0, 1, 0);
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.wait(null);
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    try std.testing.expect((try operation.finish(null)) == null);
    try closeAndDeinit(&operation);
    try closeAndDeinit(&database);
}

test "typed workflow runners preserve caller-owned operation lifecycles" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var transport = NoIoTransport{};

    var checkpoint = try database.checkpoint(null);
    try sync.runVoid(
        std.testing.allocator,
        &database,
        &checkpoint,
        &transport,
        .{},
    );

    var connect = try database.connect(null);
    var connection = try sync.runConnection(
        std.testing.allocator,
        &database,
        &connect,
        &transport,
        .{},
    );
    connection.deinit();
    try closeAndDeinit(&database);

    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 2), fixture.operations_created);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.connections_created);
    try std.testing.expectEqual(fixture.connections_created, fixture.connections_deinited);
}

test "pull distinguishes no changes from consumed and applied changes" {
    {
        sync_lifecycle_fixture_reset();
        sync_lifecycle_fixture_set(0, 0, 0, 0, 1, 0, 0, 1, 0);
        var database = try openDatabase(std.testing.allocator, null);
        var transport = NoIoTransport{};
        const summary = try sync.pull(
            std.testing.allocator,
            &database,
            &transport,
            .{},
        );
        try std.testing.expect(!summary.changes_received);
        try std.testing.expect(!summary.changes_applied);
        try closeAndDeinit(&database);

        const fixture = sync_lifecycle_fixture_stats();
        try std.testing.expectEqual(@as(u32, 1), fixture.operations_created);
        try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
        try std.testing.expectEqual(@as(u32, 0), fixture.changes_created);
    }

    {
        sync_lifecycle_fixture_reset();
        var database = try openDatabase(std.testing.allocator, null);
        var transport = NoIoTransport{};
        const summary = try sync.pull(
            std.testing.allocator,
            &database,
            &transport,
            .{},
        );
        try std.testing.expect(summary.changes_received);
        try std.testing.expect(summary.changes_applied);
        try closeAndDeinit(&database);

        const fixture = sync_lifecycle_fixture_stats();
        try std.testing.expectEqual(@as(u32, 2), fixture.operations_created);
        try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
        try std.testing.expectEqual(@as(u32, 1), fixture.changes_created);
        try std.testing.expectEqual(@as(u32, 1), fixture.changes_consumed);
        try std.testing.expectEqual(@as(u32, 0), fixture.changes_deinited);
    }
}

test "sync workflow completes push before pull and apply" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);
    var transport = NoIoTransport{};
    const summary = try sync.sync(
        std.testing.allocator,
        &database,
        &transport,
        .{},
    );
    try std.testing.expect(summary.push_completed);
    try std.testing.expect(summary.pull.changes_received);
    try std.testing.expect(summary.pull.changes_applied);
    try closeAndDeinit(&database);

    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 3), fixture.operations_created);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.changes_consumed);
    try std.testing.expectEqual(@as(u32, 1), fixture.push_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.wait_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.apply_calls);
    try std.testing.expectEqual(@as(u32, 3), fixture.workflow_sequence_len);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 1, 2, 3 },
        &fixture.workflow_sequence,
    );
}

test "workflow wait apply and push failures release ordinary intermediate owners" {
    {
        sync_lifecycle_fixture_reset();
        sync_lifecycle_fixture_set(0, 0, 1, 0, 0, 0, 0, 1, 0);
        var database = try openDatabase(std.testing.allocator, null);
        var transport = NoIoTransport{};
        try std.testing.expectError(
            error.Io,
            sync.pull(std.testing.allocator, &database, &transport, .{}),
        );
        try closeAndDeinit(&database);
        const fixture = sync_lifecycle_fixture_stats();
        try std.testing.expectEqual(@as(u32, 1), fixture.operations_created);
        try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
    }

    {
        sync_lifecycle_fixture_reset();
        sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 1, 0, 1, 0);
        var database = try openDatabase(std.testing.allocator, null);
        var transport = NoIoTransport{};
        try std.testing.expectError(
            error.Io,
            sync.pull(std.testing.allocator, &database, &transport, .{}),
        );
        try closeAndDeinit(&database);
        const fixture = sync_lifecycle_fixture_stats();
        try std.testing.expectEqual(@as(u32, 1), fixture.operations_created);
        try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
        try std.testing.expectEqual(@as(u32, 1), fixture.changes_created);
        try std.testing.expectEqual(@as(u32, 1), fixture.changes_consumed);
    }

    {
        sync_lifecycle_fixture_reset();
        sync_lifecycle_fixture_set(0, 0, 1, 0, 0, 0, 0, 1, 0);
        var database = try openDatabase(std.testing.allocator, null);
        var transport = NoIoTransport{};
        try std.testing.expectError(
            error.Io,
            sync.sync(std.testing.allocator, &database, &transport, .{}),
        );
        try closeAndDeinit(&database);
        const fixture = sync_lifecycle_fixture_stats();
        try std.testing.expectEqual(@as(u32, 1), fixture.operations_created);
        try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
        try std.testing.expectEqual(@as(u32, 0), fixture.changes_created);
    }
}

test "changes deinit and apply consume ownership on success and failure" {
    sync_lifecycle_fixture_reset();
    var database = try openDatabase(std.testing.allocator, null);

    var first_wait = try database.wait(null);
    _ = try first_wait.poll(null);
    var first = (try first_wait.finish(null)).?;
    try closeAndDeinit(&first_wait);
    first.deinit();
    first.deinit();

    var second_wait = try database.wait(null);
    _ = try second_wait.poll(null);
    var second = (try second_wait.finish(null)).?;
    try closeAndDeinit(&second_wait);
    var apply = try database.apply(&second, null);
    second.deinit();
    second.deinit();
    _ = try apply.poll(null);
    try apply.finish(null);
    try closeAndDeinit(&apply);

    var third_wait = try database.wait(null);
    _ = try third_wait.poll(null);
    var third = (try third_wait.finish(null)).?;
    try closeAndDeinit(&third_wait);
    sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 1, 0, 1, 0);
    try std.testing.expectError(error.Io, database.apply(&third, null));
    third.deinit();
    third.deinit();

    try closeAndDeinit(&database);
    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), fixture.changes_deinited);
    try std.testing.expectEqual(@as(u32, 2), fixture.changes_consumed);
    try std.testing.expectEqual(@as(u32, 1), fixture.strings_deinited);
}

test "HTTP I/O loop validates borrows bounds and exact completion" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 0, 1, 1, 0);
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.create(null);
    try std.testing.expectError(error.InvalidState, database.takeIoItem(null));
    try std.testing.expectEqual(sync.Poll.io, try operation.poll(null));
    var item = (try database.takeIoItem(null)).?;

    try std.testing.expectError(error.InvalidState, operation.poll(null));
    try std.testing.expectError(error.InvalidState, operation.close(null));
    try std.testing.expectError(error.InvalidState, database.close(null));
    try std.testing.expectError(error.InvalidState, database.stepIoCallbacks(null));
    try std.testing.expectEqual(sync.RequestKind.http, try item.requestKind(null));
    const request = try item.http(null);
    try std.testing.expectEqualStrings("", request.url);
    try std.testing.expectEqualStrings("", request.body);
    try std.testing.expectEqualStrings("POST", request.method);
    try std.testing.expectEqual(@as(usize, 2), request.header_count);
    const header = try item.httpHeader(0, null);
    try std.testing.expectEqualStrings("x-one", header.key);
    try std.testing.expectEqualStrings("", header.value);
    try std.testing.expectError(error.ColumnOutOfBounds, item.httpHeader(2, null));
    try std.testing.expectError(error.TypeMismatch, item.fullRead(null));

    try std.testing.expectError(error.InvalidState, item.done(null));
    try item.status(200, null);
    try std.testing.expectError(error.InvalidState, item.status(201, null));
    try item.pushBuffer(&.{}, null);
    try item.done(null);
    try std.testing.expectError(error.InvalidState, item.done(null));
    try closeAndDeinit(&item);
    item.deinit();
    try database.stepIoCallbacks(null);
    try std.testing.expectEqual(sync.Poll.done, try operation.poll(null));
    try operation.finish(null);
    try closeAndDeinit(&operation);
    try closeAndDeinit(&database);

    const fixture = sync_lifecycle_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), fixture.items_created);
    try std.testing.expectEqual(@as(u32, 1), fixture.items_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.status_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.buffer_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.done_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.callbacks_stepped);
}

test "full write empty content and poison form a terminal I/O path" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 0, 1, 3, 0);
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.open(null);
    _ = try operation.poll(null);
    var item = (try database.takeIoItem(null)).?;
    const request = try item.fullWrite(null);
    try std.testing.expectEqualStrings("meta.db", request.path);
    try std.testing.expectEqualStrings("", request.content);
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.InvalidState, item.close(&diagnostics));
    try std.testing.expectEqualStrings("sync I/O item must be completed or poisoned before close", diagnostics.text());
    try item.poison("", null);
    try std.testing.expectError(error.InvalidState, item.pushBuffer("late", null));
    try item.close(&diagnostics);
    item.deinit();
    item.deinit();
    try database.stepIoCallbacks(null);
    _ = try operation.poll(null);
    try operation.finish(null);
    try closeAndDeinit(&operation);
    try closeAndDeinit(&database);
    try std.testing.expectEqual(@as(u32, 1), sync_lifecycle_fixture_stats().poison_calls);
}

test "full read request exposes its borrowed path and accepts an empty result" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 0, 1, 2, 0);
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.open(null);
    _ = try operation.poll(null);
    var item = (try database.takeIoItem(null)).?;
    const request = try item.fullRead(null);
    try std.testing.expectEqualStrings("meta.db", request.path);
    try item.pushBuffer(&.{}, null);
    try item.done(null);
    try closeAndDeinit(&item);
    try database.stepIoCallbacks(null);
    _ = try operation.poll(null);
    try operation.finish(null);
    try closeAndDeinit(&operation);
    try closeAndDeinit(&database);
}

test "invalid native header count and resume failure are closed and freed" {
    sync_lifecycle_fixture_reset();
    sync_lifecycle_fixture_set(0, 0, 0, 0, 0, 0, 1, 1, 1);
    var database = try openDatabase(std.testing.allocator, null);
    var operation = try database.create(null);
    _ = try operation.poll(null);
    var item = (try database.takeIoItem(null)).?;
    try std.testing.expectError(error.InvalidState, item.http(null));
    try item.poison("bad headers", null);
    try closeAndDeinit(&item);
    try database.stepIoCallbacks(null);
    _ = try operation.poll(null);
    try operation.finish(null);
    try closeAndDeinit(&operation);

    sync_lifecycle_fixture_set(0, 0, 1, 0, 0, 0, 0, 1, 0);
    var failed = try database.stats(null);
    var diagnostics = sync.Diagnostics{};
    try std.testing.expectError(error.Io, failed.poll(&diagnostics));
    try std.testing.expectEqualStrings("resume failure", diagnostics.text());
    try closeAndDeinit(&failed);
    try closeAndDeinit(&database);
    try std.testing.expectEqual(@as(u32, 1), sync_lifecycle_fixture_stats().strings_deinited);
}

test "configuration rejects invalid values without leaking secrets" {
    sync_lifecycle_fixture_reset();
    var diagnostics = sync.Diagnostics{};
    const secret = [_]u8{ 0xff, 's', 'e', 'c', 'r', 'e', 't' };
    try std.testing.expectError(
        error.InvalidUtf8,
        sync.SyncDatabase.new(
            std.testing.allocator,
            .{ .path = "local.db" },
            .{
                .client_name = "test",
                .remote_encryption_key = &secret,
            },
            &diagnostics,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "secret") == null);
    try std.testing.expectError(
        error.InvalidState,
        sync.SyncDatabase.new(
            std.testing.allocator,
            .{ .path = "local.db" },
            .{
                .client_name = "test",
                .partial_bootstrap_prefetch = true,
            },
            &diagnostics,
        ),
    );
}

fn openDatabase(
    allocator: std.mem.Allocator,
    diagnostics: ?*sync.Diagnostics,
) !sync.SyncDatabase {
    return sync.SyncDatabase.new(
        allocator,
        .{ .path = "fixture.db" },
        .{
            .client_name = "sync-lifecycle",
            .remote_url = "https://example.invalid",
        },
        diagnostics,
    );
}

fn openAndClose(allocator: std.mem.Allocator) !void {
    var database = try openDatabase(allocator, null);
    try closeAndDeinit(&database);
}

fn closeAndDeinit(owner: anytype) !void {
    try owner.close(null);
    owner.deinit();
}

fn requireVoidDeinit(comptime Owner: type) void {
    const function = @typeInfo(@TypeOf(Owner.deinit)).@"fn";
    if (function.return_type.? != void) {
        @compileError(@typeName(Owner) ++ ".deinit must return void");
    }
}
