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
extern fn sync_transport_fixture_stats() FixtureStats;

test "standard transport accepts nested paths and treats missing reads as empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "root/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root/nested/existing.meta",
        .data = "nested-file-contents",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root/nested/replacement.meta",
        .data = "old-content",
    });

    var root = try tmp.dir.openDir(std.testing.io, "root", .{ .iterate = true });
    defer root.close(std.testing.io);
    var client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer client.deinit();
    var adapter = sync.StandardTransport{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .client = &client,
        .root_dir = root,
    };

    sync_transport_fixture_reset();
    var fake_handle_storage: usize = 0;
    var item = sync.IoItem{
        .state = null,
        .handle = @ptrCast(&fake_handle_storage),
    };
    var writer = sync.BufferWriter{
        .item = &item,
        .diagnostics = null,
    };

    try adapter.readFile("nested/existing.meta", &writer);
    var stats = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.buffer_calls);
    try std.testing.expectEqual(
        @as(u32, "nested-file-contents".len),
        stats.response_bytes,
    );

    try adapter.readFile("nested/missing.meta", &writer);
    stats = sync_transport_fixture_stats();
    try std.testing.expectEqual(@as(u32, 1), stats.buffer_calls);
    try std.testing.expectEqual(
        @as(u32, "nested-file-contents".len),
        stats.response_bytes,
    );

    try adapter.writeFileAtomically("nested/replacement.meta", "replacement");
    const replacement = try root.readFileAlloc(
        std.testing.io,
        "nested/replacement.meta",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement", replacement);
}

test "standard transport rejects non-root-relative paths before filesystem I/O" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside.meta",
        .data = "outside-sentinel",
    });

    var root = try tmp.dir.openDir(std.testing.io, "root", .{ .iterate = true });
    defer root.close(std.testing.io);
    var client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer client.deinit();
    var adapter = sync.StandardTransport{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .client = &client,
        .root_dir = root,
    };

    sync_transport_fixture_reset();
    var fake_handle_storage: usize = 0;
    var item = sync.IoItem{
        .state = null,
        .handle = @ptrCast(&fake_handle_storage),
    };
    var writer = sync.BufferWriter{
        .item = &item,
        .diagnostics = null,
    };

    const rejected_paths = [_][]const u8{
        "",
        "/absolute.meta",
        "../outside.meta",
        "nested/../../outside.meta",
        "nested/../outside.meta",
        "nested\\..\\outside.meta",
        "\\rooted.meta",
        "\\\\server\\share\\outside.meta",
        "C:\\outside.meta",
        "C:/outside.meta",
        "C:outside.meta",
        "nested//outside.meta",
        "nested/./outside.meta",
        "nested/",
    };
    for (rejected_paths) |path| {
        try std.testing.expectError(
            error.InvalidFilePath,
            adapter.readFile(path, &writer),
        );
        try std.testing.expectError(
            error.InvalidFilePath,
            adapter.writeFileAtomically(path, "mutated"),
        );
    }

    const sentinel = try tmp.dir.readFileAlloc(
        std.testing.io,
        "outside.meta",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("outside-sentinel", sentinel);
    try std.testing.expectEqual(@as(u32, 0), sync_transport_fixture_stats().buffer_calls);
    try std.testing.expectEqual(@as(usize, 0), try countEntries(root));
}

fn countEntries(dir: std.Io.Dir) !usize {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
