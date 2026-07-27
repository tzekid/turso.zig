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
    try runVoid(init.gpa, &first, try first.create(&diagnostics), &transport, options);

    var first_connection = try runConnection(
        init.gpa,
        &first,
        try first.connect(&diagnostics),
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
    try runVoid(init.gpa, &first, try first.push(&diagnostics), &transport, options);

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
    try runVoid(init.gpa, &second, try second.create(&diagnostics), &transport, options);

    var second_connection = try runConnection(
        init.gpa,
        &second,
        try second.connect(&diagnostics),
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
    try runVoid(init.gpa, &second, try second.push(&diagnostics), &transport, options);

    var wait_operation = try first.wait(&diagnostics);
    var maybe_changes = try sync.run(
        ?sync.Changes,
        init.gpa,
        &first,
        &wait_operation,
        &transport,
        options,
    );
    if (maybe_changes) |*changes| {
        defer changes.deinit();
        try runVoid(
            init.gpa,
            &first,
            try first.apply(changes, &diagnostics),
            &transport,
            options,
        );
    } else {
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
    try runVoid(
        init.gpa,
        &first,
        try first.checkpoint(&diagnostics),
        &transport,
        options,
    );

    second_connection.deinit();
    try second.close(&diagnostics);
    first_connection.deinit();
    try first.close(&diagnostics);
    std.debug.print("sync e2e push/bootstrap/pull/apply passed\n", .{});
}

fn runVoid(
    allocator: std.mem.Allocator,
    database: *sync.SyncDatabase,
    operation_value: sync.Operation(void),
    transport: anytype,
    options: sync.TransportOptions,
) !void {
    var operation = operation_value;
    return sync.run(void, allocator, database, &operation, transport, options);
}

fn runConnection(
    allocator: std.mem.Allocator,
    database: *sync.SyncDatabase,
    operation_value: sync.Operation(sync.Connection),
    transport: anytype,
    options: sync.TransportOptions,
) !sync.Connection {
    var operation = operation_value;
    return sync.run(sync.Connection, allocator, database, &operation, transport, options);
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
