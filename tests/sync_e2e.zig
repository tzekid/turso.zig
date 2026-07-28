const std = @import("std");
const sync = @import("turso_sync");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();

    const remote_url = arguments.next() orelse return error.MissingRemoteUrl;
    if (arguments.next() != null) return error.TooManyArguments;

    var diagnostics = sync.Diagnostics{};
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();
    var transport = sync.StandardTransport{
        .allocator = init.gpa,
        .io = init.io,
        .client = &client,
        .root_dir = .cwd(),
        // The harness starts a loopback-only test server. Production callers
        // keep the secure default and use HTTPS.
        .allow_http = true,
    };
    const options: sync.TransportOptions = .{ .diagnostics = &diagnostics };

    var first = try sync.SyncDatabase.new(
        init.gpa,
        .{ .path = "client-a.db" },
        .{
            .client_name = "turso-zig-e2e-a",
            .remote_url = remote_url,
            .bootstrap_if_empty = true,
            .long_poll_timeout_ms = 100,
        },
        &diagnostics,
    );
    defer first.deinit();
    var first_create = try first.create(&diagnostics);
    try sync.runVoid(init.gpa, &first, &first_create, &transport, options);

    var first_connect = try first.connect(&diagnostics);
    var first_connection = try sync.runConnection(
        init.gpa,
        &first,
        &first_connect,
        &transport,
        options,
    );
    defer first_connection.deinit();
    _ = try first_connection.exec(
        "CREATE TABLE messages(id INTEGER PRIMARY KEY, body TEXT NOT NULL)",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    _ = try first_connection.exec(
        "INSERT INTO messages VALUES (1, 'from first client')",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    const first_sync = try sync.sync(init.gpa, &first, &transport, options);
    if (!first_sync.push_completed) return error.PushDidNotComplete;

    var second = try sync.SyncDatabase.new(
        init.gpa,
        .{ .path = "client-b.db" },
        .{
            .client_name = "turso-zig-e2e-b",
            .remote_url = remote_url,
            .bootstrap_if_empty = true,
            .long_poll_timeout_ms = 100,
        },
        &diagnostics,
    );
    defer second.deinit();
    var second_create = try second.create(&diagnostics);
    try sync.runVoid(init.gpa, &second, &second_create, &transport, options);

    var second_connect = try second.connect(&diagnostics);
    var second_connection = try sync.runConnection(
        init.gpa,
        &second,
        &second_connect,
        &transport,
        options,
    );
    defer second_connection.deinit();
    try expectCount(&second_connection, 1, &diagnostics);
    _ = try second_connection.exec(
        "INSERT INTO messages VALUES (2, 'from second client')",
        &.{},
        .{ .diagnostics = &diagnostics },
    );
    var second_push = try second.push(&diagnostics);
    try sync.runVoid(init.gpa, &second, &second_push, &transport, options);

    const pull = try sync.pull(
        init.gpa,
        &first,
        &transport,
        options,
    );
    if (!pull.changes_received or !pull.changes_applied) {
        return error.MissingRemoteChanges;
    }
    try expectCount(&first_connection, 2, &diagnostics);

    var stats_operation = try first.stats(&diagnostics);
    var stats = try sync.run(
        sync.Stats,
        init.gpa,
        &first,
        &stats_operation,
        &transport,
        options,
    );
    defer stats.deinit();
    if (stats.network_sent_bytes <= 0 or stats.network_received_bytes <= 0) {
        return error.MissingNetworkEvidence;
    }
    var checkpoint = try first.checkpoint(&diagnostics);
    try sync.runVoid(
        init.gpa,
        &first,
        &checkpoint,
        &transport,
        options,
    );

    second_connection.deinit();
    try second.close(&diagnostics);
    first_connection.deinit();
    try first.close(&diagnostics);
    std.debug.print("sync e2e helpers/push/bootstrap/pull/apply passed\n", .{});
}

fn expectCount(
    connection: *sync.Connection,
    expected: i64,
    diagnostics: *sync.Diagnostics,
) !void {
    var rows = try connection.query(
        "SELECT COUNT(*) FROM messages",
        &.{},
        .{ .diagnostics = diagnostics },
    );
    defer rows.deinit();
    const row = (try rows.nextWithDiagnostics(diagnostics)) orelse return error.MissingRow;
    if (try row.get(i64, 0) != expected) return error.UnexpectedRowCount;
    if ((try rows.nextWithDiagnostics(diagnostics)) != null) return error.UnexpectedRow;
    try rows.finish(diagnostics);
}
