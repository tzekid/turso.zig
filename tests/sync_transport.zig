const std = @import("std");
const sync = @import("turso_sync");

const FixtureStats = extern struct {
    databases_created: u32,
    databases_deinited: u32,
    operations_created: u32,
    operations_deinited: u32,
    items_created: u32,
    items_deinited: u32,
    callbacks_stepped: u32,
    status_calls: u32,
    buffer_calls: u32,
    done_calls: u32,
    poison_calls: u32,
    statuses: [2]c_int,
    response_bytes: u32,
};

extern fn sync_transport_fixture_reset() void;
extern fn sync_transport_fixture_paths(
    url: [*:0]const u8,
    existing: [*:0]const u8,
    missing: [*:0]const u8,
    write: [*:0]const u8,
) void;
extern fn sync_transport_fixture_stats() FixtureStats;
extern fn sync_transport_fixture_poison() [*:0]const u8;

const FakeTransport = struct {
    request_calls: usize = 0,
    read_calls: usize = 0,
    write_calls: usize = 0,
    fail_http: bool = false,
    invalid_status: bool = false,
    fail_native_poison: bool = false,
    expected_authorization: []const u8 = "Bearer driver-secret",

    pub fn request(
        self: *FakeTransport,
        request_data: sync.TransportHttpRequest,
        writer: *sync.ResponseWriter,
    ) !void {
        try std.testing.expectEqual(@as(usize, 4), request_data.headers.len);
        try std.testing.expectEqualStrings("x-native", request_data.headers[0].name);
        try std.testing.expectEqualStrings("native-value", request_data.headers[0].value);
        try std.testing.expectEqualStrings("Authorization", request_data.headers[2].name);
        try std.testing.expectEqualStrings("Bearer stale-upper", request_data.headers[2].value);
        try std.testing.expectEqualStrings("aUtHoRiZaTiOn", request_data.headers[3].name);
        try std.testing.expectEqualStrings("Bearer stale-mixed", request_data.headers[3].value);
        try std.testing.expectEqualStrings("authorization", request_data.authorization.?.name);
        try std.testing.expectEqualStrings(
            self.expected_authorization,
            request_data.authorization.?.value,
        );

        const call = self.request_calls;
        self.request_calls += 1;
        if (self.fail_native_poison and call == 0) {
            const diagnostics = writer.buffer.diagnostics orelse
                return error.MissingPoisonFailureDiagnostics;
            diagnostics.setWrapperError("turso.zig test: fail native poison");
            return error.InjectedAfterPoisonFailure;
        }
        if (self.fail_http and call == 0) return error.InjectedHttpFailure;
        if (self.invalid_status and call == 0) {
            try writer.setStatus(70_000);
            return;
        }

        if (call == 0) {
            try std.testing.expectEqualStrings("https://example.invalid", request_data.url);
            try std.testing.expectEqualStrings("POST", request_data.method);
            try std.testing.expectEqualStrings("/sync?round=one", request_data.path);
            try std.testing.expectEqualStrings("request-body", request_data.body);
            try writer.setStatus(503);
            try writer.push("protocol-");
            try writer.push("failure");
        } else {
            try std.testing.expectEqualStrings("GET", request_data.method);
            try std.testing.expectEqualStrings("/missing", request_data.path);
            try writer.setStatus(404);
            try writer.push("not-found");
        }
    }

    pub fn readFile(
        self: *FakeTransport,
        path: []const u8,
        writer: *sync.BufferWriter,
    ) !void {
        const call = self.read_calls;
        self.read_calls += 1;
        if (call == 0) {
            try std.testing.expectEqualStrings("existing.meta", path);
            try writer.push("file-");
            try writer.push("contents");
        } else {
            try std.testing.expectEqualStrings("missing.meta", path);
            // Missing full-file reads are successful and empty.
        }
    }

    pub fn writeFileAtomically(
        self: *FakeTransport,
        path: []const u8,
        content: []const u8,
    ) !void {
        self.write_calls += 1;
        try std.testing.expectEqualStrings("write.meta", path);
        try std.testing.expectEqualStrings("atomic-replacement", content);
    }
};

test "driver drains every kind across rounds and returns copied typed stats" {
    sync_transport_fixture_reset();
    var database = try openDatabase(null);
    var operation = try database.stats(null);
    var fake = FakeTransport{};
    var stats = try sync.run(
        sync.Stats,
        std.testing.allocator,
        &database,
        &operation,
        &fake,
        .{ .authorization = .{
            .name = "authorization",
            .value = "Bearer driver-secret",
        } },
    );
    defer stats.deinit();

    try std.testing.expectEqual(@as(i64, 17), stats.cdc_operations);
    try std.testing.expectEqual(@as(i64, 29), stats.network_received_bytes);
    try std.testing.expectEqualStrings("transport-revision", stats.revision);
    try std.testing.expectEqual(@as(usize, 2), fake.request_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.read_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.write_calls);

    try closeAndDeinit(&database);
    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 5), fixture.items_created);
    try std.testing.expectEqual(fixture.items_created, fixture.items_deinited);
    try std.testing.expectEqual(@as(u32, 2), fixture.callbacks_stepped);
    try std.testing.expectEqual(@as(u32, 2), fixture.status_calls);
    try std.testing.expectEqual(@as(c_int, 503), fixture.statuses[0]);
    try std.testing.expectEqual(@as(c_int, 404), fixture.statuses[1]);
    try std.testing.expectEqual(@as(u32, 5), fixture.done_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.poison_calls);
    // Two HTTP chunks + one HTTP chunk + two full-read chunks.
    try std.testing.expectEqual(@as(u32, 5), fixture.buffer_calls);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
}

test "transport failure is redacted, poisons once, drains the round, and cleans up" {
    sync_transport_fixture_reset();
    var database = try openDatabase(null);
    var operation = try database.create(null);
    var fake = FakeTransport{
        .fail_http = true,
        .expected_authorization = "Bearer never-diagnose-this",
    };
    var diagnostics = sync.Diagnostics{};

    try std.testing.expectError(
        error.Io,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &fake,
            .{
                .authorization = .{
                    .name = "authorization",
                    .value = "Bearer never-diagnose-this",
                },
                .diagnostics = &diagnostics,
            },
        ),
    );
    try std.testing.expectEqualStrings("sync transport HTTP failure", diagnostics.text());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "never-diagnose") == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "example.invalid") == null);
    try std.testing.expectEqualStrings(
        "sync transport HTTP failure",
        std.mem.span(sync_transport_fixture_poison()),
    );

    try closeAndDeinit(&database);
    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 3), fixture.items_created);
    try std.testing.expectEqual(fixture.items_created, fixture.items_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.poison_calls);
    try std.testing.expectEqual(@as(u32, 2), fixture.done_calls);
    try std.testing.expectEqual(@as(u32, 1), fixture.callbacks_stepped);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
}

test "native poison failure retains an internal owner through repeated recovery" {
    sync_transport_fixture_reset();
    var database = try openDatabase(null);
    var operation = try database.create(null);
    var fake = FakeTransport{
        .fail_native_poison = true,
        .expected_authorization = "Bearer retained-owner-secret",
    };
    var diagnostics = sync.Diagnostics{};

    try std.testing.expectError(
        error.InjectedAfterPoisonFailure,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &fake,
            .{
                .authorization = .{
                    .name = "authorization",
                    .value = "Bearer retained-owner-secret",
                },
                .diagnostics = &diagnostics,
            },
        ),
    );
    try std.testing.expectEqualStrings("sync transport HTTP failure", diagnostics.text());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "retained-owner-secret") == null);
    try std.testing.expectError(error.InvalidState, operation.close(null));
    try std.testing.expectError(error.InvalidState, database.close(null));

    diagnostics.setWrapperError("turso.zig test: fail native poison");
    try std.testing.expectError(
        error.Misuse,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &fake,
            .{ .diagnostics = &diagnostics },
        ),
    );
    try std.testing.expectEqualStrings(
        "native sync I/O poison completion failed",
        diagnostics.text(),
    );
    try std.testing.expectError(error.InvalidState, operation.close(null));
    try std.testing.expectError(error.InvalidState, database.close(null));

    try std.testing.expectError(
        error.Io,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &fake,
            .{ .diagnostics = &diagnostics },
        ),
    );
    try closeAndDeinit(&database);

    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), fixture.items_created);
    try std.testing.expectEqual(fixture.items_created, fixture.items_deinited);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.poison_calls);
}

test "out-of-range HTTP status is poisoned without truncation or secret leakage" {
    sync_transport_fixture_reset();
    var database = try openDatabase(null);
    var operation = try database.create(null);
    var fake = FakeTransport{
        .invalid_status = true,
        .expected_authorization = "Bearer invalid-status-secret",
    };
    var diagnostics = sync.Diagnostics{};

    try std.testing.expectError(
        error.Io,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &fake,
            .{
                .authorization = .{
                    .name = "authorization",
                    .value = "Bearer invalid-status-secret",
                },
                .diagnostics = &diagnostics,
            },
        ),
    );
    try std.testing.expectEqualStrings("sync transport HTTP failure", diagnostics.text());
    try std.testing.expectEqual(@as(u32, 0), sync_transport_fixture_stats().status_calls);
    try std.testing.expectEqual(@as(u32, 1), sync_transport_fixture_stats().poison_calls);
    try closeAndDeinit(&database);
}

test "standard adapter forwards loopback HTTP and performs full-file I/O atomically" {
    sync_transport_fixture_reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "existing.meta",
        .data = "existing-full-file",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "write.meta",
        .data = "old-content",
    });

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{port},
        0,
    );
    defer std.testing.allocator.free(url);
    sync_transport_fixture_paths(
        url,
        "existing.meta",
        "missing.meta",
        "write.meta",
    );

    var server_context = ServerContext{
        .server = &server,
        .io = std.testing.io,
        .authorization_mode = .replacement,
    };
    const server_thread = try std.Thread.spawn(.{}, serveRequests, .{&server_context});

    var client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer client.deinit();
    var adapter = sync.StandardTransport{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .client = &client,
        .root_dir = tmp.dir,
        .allow_http = true,
    };

    var database = try openDatabase(null);
    var operation = try database.create(null);
    try sync.run(
        void,
        std.testing.allocator,
        &database,
        &operation,
        &adapter,
        .{ .authorization = .{
            .name = "authorization",
            .value = "Bearer loopback-secret",
        } },
    );
    try closeAndDeinit(&database);
    server_thread.join();
    if (server_context.failure) |failure| return failure;

    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(c_int, 404), fixture.statuses[0]);
    try std.testing.expectEqual(@as(c_int, 200), fixture.statuses[1]);
    try std.testing.expectEqual(@as(u32, 0), fixture.poison_calls);
    try std.testing.expectEqual(@as(u32, 5), fixture.done_calls);
    try std.testing.expectEqual(@as(u32, 2), fixture.buffer_calls);
    try std.testing.expectEqual(@as(u32, 34), fixture.response_bytes);

    const replacement = try tmp.dir.readFileAlloc(
        std.testing.io,
        "write.meta",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("atomic-replacement", replacement);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(std.testing.io, "missing.meta", .{}),
    );

    // Replacing a directory fails after the same-directory temporary is
    // created. The adapter's deferred Atomic.deinit must remove that temp.
    try tmp.dir.createDir(std.testing.io, "rename-target", .default_dir);
    const before = try countEntries(tmp.dir);
    var rename_error: ?anyerror = null;
    adapter.writeFileAtomically("rename-target", "do-not-leak") catch |err| {
        rename_error = err;
    };
    try std.testing.expect(rename_error != null);
    try std.testing.expect(!std.mem.eql(u8, @errorName(rename_error.?), "do-not-leak"));
    try std.testing.expect(!std.mem.eql(u8, @errorName(rename_error.?), "rename-target"));
    try std.testing.expectEqual(before, try countEntries(tmp.dir));
}

test "standard adapter preserves native authorization headers without injection" {
    sync_transport_fixture_reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "existing.meta",
        .data = "existing-full-file",
    });

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const url = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{server.socket.address.getPort()},
        0,
    );
    defer std.testing.allocator.free(url);
    sync_transport_fixture_paths(
        url,
        "existing.meta",
        "missing.meta",
        "write.meta",
    );

    var server_context = ServerContext{
        .server = &server,
        .io = std.testing.io,
        .authorization_mode = .preserve_native,
    };
    const server_thread = try std.Thread.spawn(.{}, serveRequests, .{&server_context});

    var client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer client.deinit();
    var adapter = sync.StandardTransport{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .client = &client,
        .root_dir = tmp.dir,
        .allow_http = true,
    };

    var database = try openDatabase(null);
    var operation = try database.create(null);
    try sync.run(
        void,
        std.testing.allocator,
        &database,
        &operation,
        &adapter,
        .{},
    );
    try closeAndDeinit(&database);
    server_thread.join();
    if (server_context.failure) |failure| return failure;

    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(c_int, 404), fixture.statuses[0]);
    try std.testing.expectEqual(@as(c_int, 200), fixture.statuses[1]);
    try std.testing.expectEqual(@as(u32, 0), fixture.poison_calls);
}

test "standard adapter failures poison with fixed diagnostics and no secret or path" {
    sync_transport_fixture_reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    sync_transport_fixture_paths(
        "http://127.0.0.1:1",
        "missing-existing.meta",
        "missing.meta",
        "private-path.meta",
    );

    var client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer client.deinit();
    var adapter = sync.StandardTransport{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .client = &client,
        .root_dir = tmp.dir,
        // Deliberately false: the deterministic policy failure occurs before
        // any network access and must still be redacted through the driver.
        .allow_http = false,
    };

    var diagnostics = sync.Diagnostics{};
    var database = try openDatabase(&diagnostics);
    var operation = try database.create(&diagnostics);
    try std.testing.expectError(
        error.Io,
        sync.run(
            void,
            std.testing.allocator,
            &database,
            &operation,
            &adapter,
            .{
                .authorization = .{
                    .name = "authorization",
                    .value = "Bearer standard-adapter-secret",
                },
                .diagnostics = &diagnostics,
            },
        ),
    );
    try std.testing.expectEqualStrings("sync transport HTTP failure", diagnostics.text());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "standard-adapter-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "private-path") == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "127.0.0.1") == null);
    try closeAndDeinit(&database);

    const fixture = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 3), fixture.items_created);
    try std.testing.expectEqual(fixture.items_created, fixture.items_deinited);
    try std.testing.expectEqual(@as(u32, 1), fixture.poison_calls);
    try std.testing.expectEqual(fixture.operations_created, fixture.operations_deinited);
}

const ServerContext = struct {
    server: *std.Io.net.Server,
    io: std.Io,
    authorization_mode: AuthorizationMode,
    failure: ?anyerror = null,
};

const AuthorizationMode = enum {
    replacement,
    preserve_native,
};

fn serveRequests(context: *ServerContext) void {
    serveRequestsFallible(context) catch |err| {
        context.failure = err;
    };
}

fn serveRequestsFallible(context: *ServerContext) !void {
    for (0..2) |request_index| {
        var stream = try context.server.accept(context.io);
        defer stream.close(context.io);
        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(context.io, &read_buffer);
        const reader = &stream_reader.interface;

        const request_line = trimCarriageReturn((try reader.takeDelimiter('\n')).?);
        if (request_index == 0) {
            if (!std.mem.eql(u8, "POST /sync?round=one HTTP/1.1", request_line))
                return error.BadPostRequestLine;
        } else {
            if (!std.mem.eql(u8, "GET /missing HTTP/1.1", request_line))
                return error.BadGetRequestLine;
        }

        var content_length: usize = 0;
        var saw_native = false;
        var saw_content_type = false;
        var authorization_count: usize = 0;
        var saw_fresh_authorization = false;
        var saw_stale_upper = false;
        var saw_stale_mixed = false;
        while (true) {
            const line = trimCarriageReturn((try reader.takeDelimiter('\n')).?);
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                content_length = try std.fmt.parseInt(
                    usize,
                    std.mem.trim(u8, line["content-length:".len..], " "),
                    10,
                );
            } else if (std.ascii.eqlIgnoreCase(line, "x-native: native-value")) {
                saw_native = true;
            } else if (std.ascii.eqlIgnoreCase(line, "content-type: application/octet-stream")) {
                saw_content_type = true;
            } else if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                authorization_count += 1;
                if (std.ascii.eqlIgnoreCase(line, "authorization: Bearer loopback-secret")) {
                    saw_fresh_authorization = true;
                } else if (std.ascii.eqlIgnoreCase(line, "authorization: Bearer stale-upper")) {
                    saw_stale_upper = true;
                } else if (std.ascii.eqlIgnoreCase(line, "authorization: Bearer stale-mixed")) {
                    saw_stale_mixed = true;
                }
            }
        }
        if (!saw_native) return error.MissingNativeHeader;
        if (!saw_content_type) return error.MissingContentTypeHeader;
        switch (context.authorization_mode) {
            .replacement => {
                if (authorization_count != 1) return error.BadAuthorizationCount;
                if (!saw_fresh_authorization) return error.MissingFreshAuthorization;
                if (saw_stale_upper or saw_stale_mixed) return error.StaleAuthorizationLeaked;
            },
            .preserve_native => {
                if (authorization_count != 2) return error.BadAuthorizationCount;
                if (saw_fresh_authorization) return error.UnexpectedFreshAuthorization;
                if (!saw_stale_upper or !saw_stale_mixed) return error.MissingNativeAuthorization;
            },
        }

        var body_buffer: [64]u8 = undefined;
        if (content_length > body_buffer.len) return error.BodyTooLong;
        try reader.readSliceAll(body_buffer[0..content_length]);
        if (request_index == 0) {
            if (!std.mem.eql(u8, "request-body", body_buffer[0..content_length]))
                return error.BadRequestBody;
            try writeResponse(
                stream,
                context.io,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 16\r\nConnection: close\r\n\r\nprotocol-non2xx!",
            );
        } else {
            if (content_length != 0) return error.UnexpectedGetBody;
            try writeResponse(
                stream,
                context.io,
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    }
}

fn writeResponse(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var stream_writer = stream.writer(io, &buffer);
    try stream_writer.interface.writeAll(bytes);
    try stream_writer.interface.flush();
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    return if (line.len != 0 and line[line.len - 1] == '\r')
        line[0 .. line.len - 1]
    else
        line;
}

fn countEntries(dir: std.Io.Dir) !usize {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

fn openDatabase(diagnostics: ?*sync.Diagnostics) !sync.SyncDatabase {
    return sync.SyncDatabase.new(
        std.testing.allocator,
        .{ .path = "fixture.db" },
        .{
            .client_name = "sync-transport",
            .remote_url = "https://example.invalid",
        },
        diagnostics,
    );
}

fn closeAndDeinit(owner: anytype) !void {
    try owner.close(null);
    owner.deinit();
}
