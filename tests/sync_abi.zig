const std = @import("std");
const raw = @import("turso_sync").raw.c;

extern fn turso_zig_sync_probe_size_io_http_request() usize;
extern fn turso_zig_sync_probe_align_io_http_request() usize;
extern fn turso_zig_sync_probe_size_io_http_header() usize;
extern fn turso_zig_sync_probe_align_io_http_header() usize;
extern fn turso_zig_sync_probe_size_io_full_read_request() usize;
extern fn turso_zig_sync_probe_align_io_full_read_request() usize;
extern fn turso_zig_sync_probe_size_io_full_write_request() usize;
extern fn turso_zig_sync_probe_align_io_full_write_request() usize;
extern fn turso_zig_sync_probe_size_stats() usize;
extern fn turso_zig_sync_probe_align_stats() usize;
extern fn turso_zig_sync_probe_size_database_config() usize;
extern fn turso_zig_sync_probe_align_database_config() usize;

extern fn turso_zig_sync_probe_offset_io_http_request_url() usize;
extern fn turso_zig_sync_probe_offset_io_http_request_method() usize;
extern fn turso_zig_sync_probe_offset_io_http_request_path() usize;
extern fn turso_zig_sync_probe_offset_io_http_request_body() usize;
extern fn turso_zig_sync_probe_offset_io_http_request_headers() usize;
extern fn turso_zig_sync_probe_offset_io_http_header_key() usize;
extern fn turso_zig_sync_probe_offset_io_http_header_value() usize;
extern fn turso_zig_sync_probe_offset_io_full_read_request_path() usize;
extern fn turso_zig_sync_probe_offset_io_full_write_request_path() usize;
extern fn turso_zig_sync_probe_offset_io_full_write_request_content() usize;
extern fn turso_zig_sync_probe_offset_stats_cdc_operations() usize;
extern fn turso_zig_sync_probe_offset_stats_main_wal_size() usize;
extern fn turso_zig_sync_probe_offset_stats_revert_wal_size() usize;
extern fn turso_zig_sync_probe_offset_stats_last_pull_unix_time() usize;
extern fn turso_zig_sync_probe_offset_stats_last_push_unix_time() usize;
extern fn turso_zig_sync_probe_offset_stats_network_sent_bytes() usize;
extern fn turso_zig_sync_probe_offset_stats_network_received_bytes() usize;
extern fn turso_zig_sync_probe_offset_stats_revision() usize;
extern fn turso_zig_sync_probe_offset_database_config_path() usize;
extern fn turso_zig_sync_probe_offset_database_config_remote_url() usize;
extern fn turso_zig_sync_probe_offset_database_config_client_name() usize;
extern fn turso_zig_sync_probe_offset_database_config_long_poll_timeout_ms() usize;
extern fn turso_zig_sync_probe_offset_database_config_bootstrap_if_empty() usize;
extern fn turso_zig_sync_probe_offset_database_config_reserved_bytes() usize;
extern fn turso_zig_sync_probe_offset_database_config_partial_bootstrap_strategy_prefix() usize;
extern fn turso_zig_sync_probe_offset_database_config_partial_bootstrap_strategy_query() usize;
extern fn turso_zig_sync_probe_offset_database_config_partial_bootstrap_segment_size() usize;
extern fn turso_zig_sync_probe_offset_database_config_partial_bootstrap_prefetch() usize;
extern fn turso_zig_sync_probe_offset_database_config_remote_encryption_key() usize;
extern fn turso_zig_sync_probe_offset_database_config_remote_encryption_cipher() usize;
extern fn turso_zig_sync_probe_offset_database_config_push_operations_threshold() usize;
extern fn turso_zig_sync_probe_offset_database_config_pull_bytes_threshold() usize;
extern fn turso_zig_sync_probe_offset_database_config_logical_mvcc_pull() usize;
extern fn turso_zig_sync_probe_function_signatures() c_int;

test "all pinned sync constants retain their ABI values" {
    const constants = .{
        .{ raw.TURSO_SYNC_IO_NONE, 0 },
        .{ raw.TURSO_SYNC_IO_HTTP, 1 },
        .{ raw.TURSO_SYNC_IO_FULL_READ, 2 },
        .{ raw.TURSO_SYNC_IO_FULL_WRITE, 3 },
        .{ raw.TURSO_ASYNC_RESULT_NONE, 0 },
        .{ raw.TURSO_ASYNC_RESULT_CONNECTION, 1 },
        .{ raw.TURSO_ASYNC_RESULT_CHANGES, 2 },
        .{ raw.TURSO_ASYNC_RESULT_STATS, 3 },
    };
    inline for (constants) |pair| {
        try std.testing.expectEqual(@as(c_int, pair[1]), pair[0]);
    }
}

test "vendored sync header body has the pinned digest" {
    const vendored = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "include/turso_sync.h",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(vendored);
    const start = std.mem.indexOf(u8, vendored, "#ifndef TURSO_SYNC_H") orelse return error.HeaderBodyMissing;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(vendored[start..], &actual, .{});
    const expected = [_]u8{
        0x38, 0xb9, 0xdc, 0x73, 0xfc, 0x2f, 0xe4, 0x5c,
        0x3d, 0x86, 0xd6, 0x9f, 0xf2, 0xad, 0x48, 0xb8,
        0xc9, 0x9d, 0x69, 0x3a, 0x44, 0x62, 0x51, 0x4e,
        0xa5, 0x0f, 0xb8, 0x76, 0xab, 0xa6, 0xee, 0x35,
    };
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "sync public structs retain independent Zig and C layout" {
    const SliceRef = extern struct {
        ptr: ?*const anyopaque,
        len: usize,
    };
    const HttpRequest = extern struct {
        url: SliceRef,
        method: SliceRef,
        path: SliceRef,
        body: SliceRef,
        headers: i32,
    };
    const HttpHeader = extern struct {
        key: SliceRef,
        value: SliceRef,
    };
    const FullReadRequest = extern struct {
        path: SliceRef,
    };
    const FullWriteRequest = extern struct {
        path: SliceRef,
        content: SliceRef,
    };
    const Stats = extern struct {
        cdc_operations: i64,
        main_wal_size: i64,
        revert_wal_size: i64,
        last_pull_unix_time: i64,
        last_push_unix_time: i64,
        network_sent_bytes: i64,
        network_received_bytes: i64,
        revision: SliceRef,
    };
    const DatabaseConfig = extern struct {
        path: [*c]const u8,
        remote_url: [*c]const u8,
        client_name: [*c]const u8,
        long_poll_timeout_ms: i32,
        bootstrap_if_empty: bool,
        reserved_bytes: i32,
        partial_bootstrap_strategy_prefix: i32,
        partial_bootstrap_strategy_query: [*c]const u8,
        partial_bootstrap_segment_size: usize,
        partial_bootstrap_prefetch: bool,
        remote_encryption_key: [*c]const u8,
        remote_encryption_cipher: [*c]const u8,
        push_operations_threshold: usize,
        pull_bytes_threshold: usize,
        logical_mvcc_pull: bool,
    };

    try expectLayout(raw.turso_sync_io_http_request_t, HttpRequest);
    try expectLayout(raw.turso_sync_io_http_header_t, HttpHeader);
    try expectLayout(raw.turso_sync_io_full_read_request_t, FullReadRequest);
    try expectLayout(raw.turso_sync_io_full_write_request_t, FullWriteRequest);
    try expectLayout(raw.turso_sync_stats_t, Stats);
    try expectLayout(raw.turso_sync_database_config_t, DatabaseConfig);
    try std.testing.expectEqual(@offsetOf(DatabaseConfig, "logical_mvcc_pull"), @offsetOf(raw.turso_sync_database_config_t, "logical_mvcc_pull"));
}

test "independent C probe agrees with every sync struct field" {
    try expectProbe(raw.turso_sync_io_http_request_t, turso_zig_sync_probe_size_io_http_request, turso_zig_sync_probe_align_io_http_request);
    try expectProbe(raw.turso_sync_io_http_header_t, turso_zig_sync_probe_size_io_http_header, turso_zig_sync_probe_align_io_http_header);
    try expectProbe(raw.turso_sync_io_full_read_request_t, turso_zig_sync_probe_size_io_full_read_request, turso_zig_sync_probe_align_io_full_read_request);
    try expectProbe(raw.turso_sync_io_full_write_request_t, turso_zig_sync_probe_size_io_full_write_request, turso_zig_sync_probe_align_io_full_write_request);
    try expectProbe(raw.turso_sync_stats_t, turso_zig_sync_probe_size_stats, turso_zig_sync_probe_align_stats);
    try expectProbe(raw.turso_sync_database_config_t, turso_zig_sync_probe_size_database_config, turso_zig_sync_probe_align_database_config);

    try expectOffset(raw.turso_sync_io_http_request_t, "url", turso_zig_sync_probe_offset_io_http_request_url);
    try expectOffset(raw.turso_sync_io_http_request_t, "method", turso_zig_sync_probe_offset_io_http_request_method);
    try expectOffset(raw.turso_sync_io_http_request_t, "path", turso_zig_sync_probe_offset_io_http_request_path);
    try expectOffset(raw.turso_sync_io_http_request_t, "body", turso_zig_sync_probe_offset_io_http_request_body);
    try expectOffset(raw.turso_sync_io_http_request_t, "headers", turso_zig_sync_probe_offset_io_http_request_headers);
    try expectOffset(raw.turso_sync_io_http_header_t, "key", turso_zig_sync_probe_offset_io_http_header_key);
    try expectOffset(raw.turso_sync_io_http_header_t, "value", turso_zig_sync_probe_offset_io_http_header_value);
    try expectOffset(raw.turso_sync_io_full_read_request_t, "path", turso_zig_sync_probe_offset_io_full_read_request_path);
    try expectOffset(raw.turso_sync_io_full_write_request_t, "path", turso_zig_sync_probe_offset_io_full_write_request_path);
    try expectOffset(raw.turso_sync_io_full_write_request_t, "content", turso_zig_sync_probe_offset_io_full_write_request_content);
    try expectOffset(raw.turso_sync_stats_t, "cdc_operations", turso_zig_sync_probe_offset_stats_cdc_operations);
    try expectOffset(raw.turso_sync_stats_t, "main_wal_size", turso_zig_sync_probe_offset_stats_main_wal_size);
    try expectOffset(raw.turso_sync_stats_t, "revert_wal_size", turso_zig_sync_probe_offset_stats_revert_wal_size);
    try expectOffset(raw.turso_sync_stats_t, "last_pull_unix_time", turso_zig_sync_probe_offset_stats_last_pull_unix_time);
    try expectOffset(raw.turso_sync_stats_t, "last_push_unix_time", turso_zig_sync_probe_offset_stats_last_push_unix_time);
    try expectOffset(raw.turso_sync_stats_t, "network_sent_bytes", turso_zig_sync_probe_offset_stats_network_sent_bytes);
    try expectOffset(raw.turso_sync_stats_t, "network_received_bytes", turso_zig_sync_probe_offset_stats_network_received_bytes);
    try expectOffset(raw.turso_sync_stats_t, "revision", turso_zig_sync_probe_offset_stats_revision);
    try expectOffset(raw.turso_sync_database_config_t, "path", turso_zig_sync_probe_offset_database_config_path);
    try expectOffset(raw.turso_sync_database_config_t, "remote_url", turso_zig_sync_probe_offset_database_config_remote_url);
    try expectOffset(raw.turso_sync_database_config_t, "client_name", turso_zig_sync_probe_offset_database_config_client_name);
    try expectOffset(raw.turso_sync_database_config_t, "long_poll_timeout_ms", turso_zig_sync_probe_offset_database_config_long_poll_timeout_ms);
    try expectOffset(raw.turso_sync_database_config_t, "bootstrap_if_empty", turso_zig_sync_probe_offset_database_config_bootstrap_if_empty);
    try expectOffset(raw.turso_sync_database_config_t, "reserved_bytes", turso_zig_sync_probe_offset_database_config_reserved_bytes);
    try expectOffset(raw.turso_sync_database_config_t, "partial_bootstrap_strategy_prefix", turso_zig_sync_probe_offset_database_config_partial_bootstrap_strategy_prefix);
    try expectOffset(raw.turso_sync_database_config_t, "partial_bootstrap_strategy_query", turso_zig_sync_probe_offset_database_config_partial_bootstrap_strategy_query);
    try expectOffset(raw.turso_sync_database_config_t, "partial_bootstrap_segment_size", turso_zig_sync_probe_offset_database_config_partial_bootstrap_segment_size);
    try expectOffset(raw.turso_sync_database_config_t, "partial_bootstrap_prefetch", turso_zig_sync_probe_offset_database_config_partial_bootstrap_prefetch);
    try expectOffset(raw.turso_sync_database_config_t, "remote_encryption_key", turso_zig_sync_probe_offset_database_config_remote_encryption_key);
    try expectOffset(raw.turso_sync_database_config_t, "remote_encryption_cipher", turso_zig_sync_probe_offset_database_config_remote_encryption_cipher);
    try expectOffset(raw.turso_sync_database_config_t, "push_operations_threshold", turso_zig_sync_probe_offset_database_config_push_operations_threshold);
    try expectOffset(raw.turso_sync_database_config_t, "pull_bytes_threshold", turso_zig_sync_probe_offset_database_config_pull_bytes_threshold);
    try expectOffset(raw.turso_sync_database_config_t, "logical_mvcc_pull", turso_zig_sync_probe_offset_database_config_logical_mvcc_pull);
    try std.testing.expectEqual(@as(c_int, 1), turso_zig_sync_probe_function_signatures());
}

test "all 29 sync SDK entry points retain Zig C signatures" {
    comptime {
        assertCFunction(raw.turso_sync_database_new, 4);
        assertCFunction(raw.turso_sync_database_open, 3);
        assertCFunction(raw.turso_sync_database_create, 3);
        assertCFunction(raw.turso_sync_database_connect, 3);
        assertCFunction(raw.turso_sync_database_stats, 3);
        assertCFunction(raw.turso_sync_database_checkpoint, 3);
        assertCFunction(raw.turso_sync_database_push_changes, 3);
        assertCFunction(raw.turso_sync_database_wait_changes, 3);
        assertCFunction(raw.turso_sync_database_apply_changes, 4);
        assertCFunction(raw.turso_sync_operation_resume, 2);
        assertCFunction(raw.turso_sync_operation_result_kind, 1);
        assertCFunction(raw.turso_sync_operation_result_extract_connection, 2);
        assertCFunction(raw.turso_sync_operation_result_extract_changes, 2);
        assertCFunction(raw.turso_sync_operation_result_extract_stats, 2);
        assertCFunction(raw.turso_sync_database_io_take_item, 3);
        assertCFunction(raw.turso_sync_database_io_step_callbacks, 2);
        assertCFunction(raw.turso_sync_database_io_request_kind, 1);
        assertCFunction(raw.turso_sync_database_io_request_http, 2);
        assertCFunction(raw.turso_sync_database_io_request_http_header, 3);
        assertCFunction(raw.turso_sync_database_io_request_full_read, 2);
        assertCFunction(raw.turso_sync_database_io_request_full_write, 2);
        assertCFunction(raw.turso_sync_database_io_poison, 2);
        assertCFunction(raw.turso_sync_database_io_status, 2);
        assertCFunction(raw.turso_sync_database_io_push_buffer, 2);
        assertCFunction(raw.turso_sync_database_io_done, 1);
        assertCFunction(raw.turso_sync_database_deinit, 1);
        assertCFunction(raw.turso_sync_operation_deinit, 1);
        assertCFunction(raw.turso_sync_database_io_item_deinit, 1);
        assertCFunction(raw.turso_sync_changes_deinit, 1);
    }
}

test "sync raw ABI creates and starts an open operation" {
    var base_config = std.mem.zeroes(raw.turso_database_config_t);
    base_config.path = ":memory:";

    var sync_config = std.mem.zeroes(raw.turso_sync_database_config_t);
    sync_config.path = ":memory:";
    sync_config.client_name = "turso-zig-sync-abi";
    sync_config.bootstrap_if_empty = true;
    sync_config.logical_mvcc_pull = true;

    var error_message: [*c]const u8 = null;
    var database: ?*const raw.turso_sync_database_t = null;
    try expectStatus(
        raw.TURSO_OK,
        raw.turso_sync_database_new(&base_config, &sync_config, &database, &error_message),
        error_message,
    );
    defer raw.turso_sync_database_deinit(database);

    var operation: ?*const raw.turso_sync_operation_t = null;
    error_message = null;
    try expectStatus(
        raw.TURSO_OK,
        raw.turso_sync_database_create(database, &operation, &error_message),
        error_message,
    );
    defer raw.turso_sync_operation_deinit(operation);

    error_message = null;
    try expectStatus(raw.TURSO_IO, raw.turso_sync_operation_resume(operation, &error_message), error_message);
    try std.testing.expectEqual(
        @as(raw.turso_sync_operation_result_type_t, raw.TURSO_ASYNC_RESULT_NONE),
        raw.turso_sync_operation_result_kind(operation),
    );

    error_message = null;
    try expectStatus(raw.TURSO_IO, raw.turso_sync_operation_resume(operation, &error_message), error_message);

    var item: ?*const raw.turso_sync_io_item_t = null;
    error_message = null;
    try expectStatus(
        raw.TURSO_OK,
        raw.turso_sync_database_io_take_item(database, &item, &error_message),
        error_message,
    );
    try std.testing.expect(item != null);
    defer raw.turso_sync_database_io_item_deinit(item);
    try std.testing.expectEqual(
        @as(raw.turso_sync_io_request_type_t, raw.TURSO_SYNC_IO_HTTP),
        raw.turso_sync_database_io_request_kind(item),
    );
}

fn expectStatus(expected: raw.turso_status_code_t, actual: raw.turso_status_code_t, error_message: [*c]const u8) !void {
    defer if (error_message != null) raw.turso_str_deinit(error_message);
    if (actual == expected) return;
    if (error_message != null) {
        std.debug.print("unexpected Turso sync status {d}; expected {d}: {s}\n", .{ actual, expected, error_message });
    }
    return error.UnexpectedTursoStatus;
}

fn expectLayout(comptime Actual: type, comptime Expected: type) !void {
    try std.testing.expectEqual(@sizeOf(Expected), @sizeOf(Actual));
    try std.testing.expectEqual(@alignOf(Expected), @alignOf(Actual));
}

fn expectProbe(
    comptime Actual: type,
    size_probe: *const fn () callconv(.c) usize,
    align_probe: *const fn () callconv(.c) usize,
) !void {
    try std.testing.expectEqual(@sizeOf(Actual), size_probe());
    try std.testing.expectEqual(@alignOf(Actual), align_probe());
}

fn expectOffset(
    comptime Actual: type,
    comptime field: []const u8,
    offset_probe: *const fn () callconv(.c) usize,
) !void {
    try std.testing.expectEqual(@offsetOf(Actual, field), offset_probe());
}

fn assertCFunction(comptime function: anytype, comptime parameter_count: usize) void {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (info.params.len != parameter_count) @compileError("pinned sync SDK Kit function arity changed");
    if (std.meta.activeTag(info.calling_convention) != std.meta.activeTag(std.builtin.CallingConvention.c)) {
        @compileError("sync SDK Kit declaration lost the C calling convention");
    }
}
