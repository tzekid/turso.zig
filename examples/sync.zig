const std = @import("std");
const sync = @import("turso_sync");

pub fn main(init: std.process.Init) !void {
    var diagnostics = sync.Diagnostics{};
    run(init, &diagnostics) catch |err| {
        if (diagnostics.text().len != 0) {
            std.debug.print("sync failed ({s}): {s}\n", .{ @errorName(err), diagnostics.text() });
        }
        return err;
    };
}

fn run(init: std.process.Init, diagnostics: *sync.Diagnostics) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();

    const database_path = arguments.next() orelse return printUsage();
    const remote_url = arguments.next() orelse return printUsage();
    const token_path = arguments.next() orelse return printUsage();
    const message = arguments.next() orelse "hello from Zig";
    if (arguments.next() != null) return printUsage();

    const authorization_storage = try readAuthorization(init, token_path);
    defer if (authorization_storage) |storage| {
        std.crypto.secureZero(u8, storage);
        init.gpa.free(storage);
    };
    const authorization: ?sync.TransportHeader = if (authorization_storage) |storage|
        .{ .name = "authorization", .value = storage }
    else
        null;

    var database = try sync.SyncDatabase.new(
        init.gpa,
        .{ .path = database_path },
        .{
            .client_name = "turso-zig-sync-example",
            .remote_url = remote_url,
            .bootstrap_if_empty = true,
            .long_poll_timeout_ms = 1_000,
        },
        diagnostics,
    );
    defer database.deinit();

    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();
    var transport = sync.StandardTransport{
        .allocator = init.gpa,
        .io = init.io,
        .client = &client,
        // Scope full-file sync requests to the current working directory.
        .root_dir = .cwd(),
        .allow_http = isLoopbackHttp(remote_url),
    };
    const options: sync.TransportOptions = .{
        .authorization = authorization,
        .diagnostics = diagnostics,
    };

    var create_operation = try database.create(diagnostics);
    try sync.runVoid(
        init.gpa,
        &database,
        &create_operation,
        &transport,
        options,
    );
    var connect_operation = try database.connect(diagnostics);
    var connection = try sync.runConnection(
        init.gpa,
        &database,
        &connect_operation,
        &transport,
        options,
    );
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE IF NOT EXISTS zig_messages(" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)",
        &.{},
        .{ .diagnostics = diagnostics },
    );
    _ = try connection.execParams(
        "INSERT INTO zig_messages(body) VALUES (?1)",
        .{message},
        .{ .diagnostics = diagnostics },
    );
    var push_operation = try database.push(diagnostics);
    try sync.runVoid(
        init.gpa,
        &database,
        &push_operation,
        &transport,
        options,
    );

    const pull_summary = try sync.pull(init.gpa, &database, &transport, options);
    const row_count = try queryCount(&connection, diagnostics);

    var stats_operation = try database.stats(diagnostics);
    var stats = try sync.run(
        sync.Stats,
        init.gpa,
        &database,
        &stats_operation,
        &transport,
        options,
    );
    defer stats.deinit();
    var checkpoint_operation = try database.checkpoint(diagnostics);
    try sync.runVoid(
        init.gpa,
        &database,
        &checkpoint_operation,
        &transport,
        options,
    );

    std.debug.print(
        "sync complete: rows={d} pulled={} sent={d}B received={d}B revision={s}\n",
        .{
            row_count,
            pull_summary.changes_applied,
            stats.network_sent_bytes,
            stats.network_received_bytes,
            stats.revision,
        },
    );

    connection.deinit();
    try database.close(diagnostics);
}

fn readAuthorization(init: std.process.Init, token_path: []const u8) !?[]u8 {
    if (std.mem.eql(u8, token_path, "-")) return null;

    const token_storage = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        token_path,
        init.gpa,
        .limited(16 * 1024),
    );
    defer {
        std.crypto.secureZero(u8, token_storage);
        init.gpa.free(token_storage);
    }
    const token = std.mem.trim(u8, token_storage, " \t\r\n");
    if (token.len == 0) return error.EmptyAuthorizationToken;
    const authorization = try std.fmt.allocPrint(init.gpa, "Bearer {s}", .{token});
    return authorization;
}

fn queryCount(connection: *sync.Connection, diagnostics: *sync.Diagnostics) !i64 {
    var rows = try connection.query(
        "SELECT COUNT(*) FROM zig_messages",
        &.{},
        .{ .diagnostics = diagnostics },
    );
    defer rows.deinit();
    const row = (try rows.nextWithDiagnostics(diagnostics)) orelse return error.MissingRow;
    const count = try row.get(i64, 0);
    try rows.finish(diagnostics);
    return count;
}

fn isLoopbackHttp(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http")) return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return false;
    return std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host.bytes, "localhost");
}

fn printUsage() error{MissingConfiguration} {
    std.debug.print(
        "usage: turso-sync <local-db> <remote-url> <auth-token-file|-> [message]\n" ++
            "use '-' only for an unauthenticated loopback server; HTTPS remains the default\n",
        .{},
    );
    return error.MissingConfiguration;
}
