const std = @import("std");
const turso_raw = @import("turso_raw");
const raw = turso_raw.c;

extern fn turso_zig_probe_size_slice_ref() usize;
extern fn turso_zig_probe_align_slice_ref() usize;
extern fn turso_zig_probe_size_extension_text() usize;
extern fn turso_zig_probe_align_extension_text() usize;
extern fn turso_zig_probe_size_extension_blob() usize;
extern fn turso_zig_probe_align_extension_blob() usize;
extern fn turso_zig_probe_size_extension_error() usize;
extern fn turso_zig_probe_align_extension_error() usize;
extern fn turso_zig_probe_size_extension_value_data() usize;
extern fn turso_zig_probe_align_extension_value_data() usize;
extern fn turso_zig_probe_size_value() usize;
extern fn turso_zig_probe_align_value() usize;
extern fn turso_zig_probe_size_agg_ctx() usize;
extern fn turso_zig_probe_align_agg_ctx() usize;
extern fn turso_zig_probe_size_log() usize;
extern fn turso_zig_probe_align_log() usize;
extern fn turso_zig_probe_size_config() usize;
extern fn turso_zig_probe_align_config() usize;
extern fn turso_zig_probe_size_page_codec_header_info() usize;
extern fn turso_zig_probe_align_page_codec_header_info() usize;
extern fn turso_zig_probe_size_page_codec_v1() usize;
extern fn turso_zig_probe_align_page_codec_v1() usize;
extern fn turso_zig_probe_size_database_config() usize;
extern fn turso_zig_probe_align_database_config() usize;

extern fn turso_zig_probe_offset_slice_ref_ptr() usize;
extern fn turso_zig_probe_offset_slice_ref_len() usize;
extern fn turso_zig_probe_offset_extension_text_subtype() usize;
extern fn turso_zig_probe_offset_extension_text_text() usize;
extern fn turso_zig_probe_offset_extension_text_len() usize;
extern fn turso_zig_probe_offset_extension_blob_data() usize;
extern fn turso_zig_probe_offset_extension_blob_size() usize;
extern fn turso_zig_probe_offset_extension_error_code() usize;
extern fn turso_zig_probe_offset_extension_error_message() usize;
extern fn turso_zig_probe_offset_value_value_type() usize;
extern fn turso_zig_probe_offset_value_value() usize;
extern fn turso_zig_probe_offset_agg_ctx_state() usize;
extern fn turso_zig_probe_offset_log_message() usize;
extern fn turso_zig_probe_offset_log_target() usize;
extern fn turso_zig_probe_offset_log_file() usize;
extern fn turso_zig_probe_offset_log_timestamp() usize;
extern fn turso_zig_probe_offset_log_line() usize;
extern fn turso_zig_probe_offset_log_level() usize;
extern fn turso_zig_probe_offset_config_logger() usize;
extern fn turso_zig_probe_offset_config_log_level() usize;
extern fn turso_zig_probe_offset_page_codec_header_info_page_size() usize;
extern fn turso_zig_probe_offset_page_codec_header_info_reserved_space() usize;
extern fn turso_zig_probe_offset_page_codec_header_info_is_supported() usize;
extern fn turso_zig_probe_offset_page_codec_v1_abi_version() usize;
extern fn turso_zig_probe_offset_page_codec_v1_ctx() usize;
extern fn turso_zig_probe_offset_page_codec_v1_reserved_space() usize;
extern fn turso_zig_probe_offset_page_codec_v1_codec_id() usize;
extern fn turso_zig_probe_offset_page_codec_v1_destroy() usize;
extern fn turso_zig_probe_offset_page_codec_v1_probe_header() usize;
extern fn turso_zig_probe_offset_page_codec_v1_decode_page() usize;
extern fn turso_zig_probe_offset_page_codec_v1_encode_page() usize;
extern fn turso_zig_probe_offset_database_config_async_io() usize;
extern fn turso_zig_probe_offset_database_config_path() usize;
extern fn turso_zig_probe_offset_database_config_experimental_features() usize;
extern fn turso_zig_probe_offset_database_config_vfs() usize;
extern fn turso_zig_probe_offset_database_config_encryption_cipher() usize;
extern fn turso_zig_probe_offset_database_config_encryption_hexkey() usize;
extern fn turso_zig_probe_offset_database_config_page_codec() usize;
extern fn turso_zig_probe_offset_database_config_open_flags() usize;
extern fn turso_zig_probe_callback_signatures() c_int;

test "all pinned enum constants retain their ABI values" {
    const constants = .{
        .{ raw.TURSO_OK, 0 },
        .{ raw.TURSO_DONE, 1 },
        .{ raw.TURSO_ROW, 2 },
        .{ raw.TURSO_IO, 3 },
        .{ raw.TURSO_BUSY, 4 },
        .{ raw.TURSO_INTERRUPT, 5 },
        .{ raw.TURSO_BUSY_SNAPSHOT, 6 },
        .{ raw.TURSO_ERROR, 127 },
        .{ raw.TURSO_MISUSE, 128 },
        .{ raw.TURSO_CONSTRAINT, 129 },
        .{ raw.TURSO_READONLY, 130 },
        .{ raw.TURSO_DATABASE_FULL, 131 },
        .{ raw.TURSO_NOTADB, 132 },
        .{ raw.TURSO_CORRUPT, 133 },
        .{ raw.TURSO_IOERR, 134 },
        .{ raw.TURSO_TYPE_UNKNOWN, 0 },
        .{ raw.TURSO_TYPE_INTEGER, 1 },
        .{ raw.TURSO_TYPE_REAL, 2 },
        .{ raw.TURSO_TYPE_TEXT, 3 },
        .{ raw.TURSO_TYPE_BLOB, 4 },
        .{ raw.TURSO_TYPE_NULL, 5 },
        .{ raw.TURSO_EXTENSION_VALUE_NULL, 0 },
        .{ raw.TURSO_EXTENSION_VALUE_INTEGER, 1 },
        .{ raw.TURSO_EXTENSION_VALUE_FLOAT, 2 },
        .{ raw.TURSO_EXTENSION_VALUE_TEXT, 3 },
        .{ raw.TURSO_EXTENSION_VALUE_BLOB, 4 },
        .{ raw.TURSO_EXTENSION_VALUE_ERROR, 5 },
        .{ raw.TURSO_EXTENSION_RESULT_OK, 0 },
        .{ raw.TURSO_EXTENSION_RESULT_ERROR, 1 },
        .{ raw.TURSO_EXTENSION_RESULT_INVALID_ARGS, 2 },
        .{ raw.TURSO_EXTENSION_RESULT_UNKNOWN, 3 },
        .{ raw.TURSO_EXTENSION_RESULT_OOM, 4 },
        .{ raw.TURSO_EXTENSION_RESULT_CORRUPT, 5 },
        .{ raw.TURSO_EXTENSION_RESULT_NOT_FOUND, 6 },
        .{ raw.TURSO_EXTENSION_RESULT_ALREADY_EXISTS, 7 },
        .{ raw.TURSO_EXTENSION_RESULT_PERMISSION_DENIED, 8 },
        .{ raw.TURSO_EXTENSION_RESULT_ABORTED, 9 },
        .{ raw.TURSO_EXTENSION_RESULT_OUT_OF_RANGE, 10 },
        .{ raw.TURSO_EXTENSION_RESULT_UNIMPLEMENTED, 11 },
        .{ raw.TURSO_EXTENSION_RESULT_INTERNAL, 12 },
        .{ raw.TURSO_EXTENSION_RESULT_UNAVAILABLE, 13 },
        .{ raw.TURSO_EXTENSION_RESULT_CUSTOM_ERROR, 14 },
        .{ raw.TURSO_EXTENSION_RESULT_EOF, 15 },
        .{ raw.TURSO_EXTENSION_RESULT_READ_ONLY, 16 },
        .{ raw.TURSO_EXTENSION_RESULT_ROWID, 17 },
        .{ raw.TURSO_EXTENSION_RESULT_ROW, 18 },
        .{ raw.TURSO_EXTENSION_RESULT_INTERRUPT, 19 },
        .{ raw.TURSO_EXTENSION_RESULT_BUSY, 20 },
        .{ raw.TURSO_EXTENSION_RESULT_CONSTRAINT_VIOLATION, 21 },
        .{ raw.TURSO_EXTENSION_TEXT_TEXT, 0 },
        .{ raw.TURSO_EXTENSION_TEXT_JSON, 1 },
        .{ raw.TURSO_COLUMN_KIND_NONE, -1 },
        .{ raw.TURSO_COLUMN_KIND_BUILTIN, 0 },
        .{ raw.TURSO_COLUMN_KIND_CUSTOM, 1 },
        .{ raw.TURSO_COLUMN_KIND_DOMAIN, 2 },
        .{ raw.TURSO_COLUMN_KIND_STRUCT, 3 },
        .{ raw.TURSO_COLUMN_KIND_UNION, 4 },
        .{ raw.TURSO_TRACING_LEVEL_ERROR, 1 },
        .{ raw.TURSO_TRACING_LEVEL_WARN, 2 },
        .{ raw.TURSO_TRACING_LEVEL_INFO, 3 },
        .{ raw.TURSO_TRACING_LEVEL_DEBUG, 4 },
        .{ raw.TURSO_TRACING_LEVEL_TRACE, 5 },
        .{ raw.TURSO_CODEC_LOCATION_DATABASE, 0 },
        .{ raw.TURSO_CODEC_LOCATION_WAL, 1 },
        .{ raw.TURSO_DATABASE_OPEN_DEFAULT, 0 },
        .{ raw.TURSO_DATABASE_OPEN_READONLY, 1 },
    };
    inline for (constants) |pair| {
        try std.testing.expectEqual(@as(c_int, pair[1]), pair[0]);
    }
}

test "vendored upstream header body has the pinned digest" {
    const vendored = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "include/turso.h",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(vendored);
    const start = std.mem.indexOf(u8, vendored, "#ifndef TURSO_H") orelse return error.HeaderBodyMissing;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(vendored[start..], &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, turso_raw.version.upstream_header_sha256);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "core public structs retain C layout" {
    const SliceRef = extern struct { ptr: ?*const anyopaque, len: usize };
    const ExtensionText = extern struct {
        subtype: raw.turso_extension_text_subtype_t,
        text: [*c]const u8,
        len: u32,
    };
    const ExtensionBlob = extern struct {
        data: [*c]const u8,
        size: u64,
    };
    const ExtensionError = extern struct {
        code: raw.turso_extension_result_code_t,
        message: [*c]raw.turso_extension_text_t,
    };
    const ExtensionValueData = extern union {
        int_value: i64,
        float_value: f64,
        text: [*c]const raw.turso_extension_text_t,
        blob: [*c]const raw.turso_extension_blob_t,
        @"error": [*c]const raw.turso_extension_error_t,
    };
    const ExtensionValue = extern struct {
        value_type: raw.turso_extension_value_type_t,
        value: ExtensionValueData,
    };
    const AggregateContext = extern struct { state: ?*anyopaque };
    const Log = extern struct {
        message: [*c]const u8,
        target: [*c]const u8,
        file: [*c]const u8,
        timestamp: u64,
        line: usize,
        level: raw.turso_tracing_level_t,
    };
    const PageCodecHeaderInfo = extern struct {
        page_size: u32,
        reserved_space: u8,
        is_supported: u8,
    };
    const PageCodecProbeHeader = ?*const fn (
        ?*anyopaque,
        [*c]const u8,
        usize,
        [*c]PageCodecHeaderInfo,
        [*c][*c]const u8,
    ) callconv(.c) i32;
    const PageCodecTransform = ?*const fn (
        ?*anyopaque,
        u32,
        c_uint,
        [*c]const u8,
        usize,
        [*c]u8,
        usize,
        [*c][*c]const u8,
    ) callconv(.c) i32;
    const PageCodecDestroy = ?*const fn (?*anyopaque) callconv(.c) void;
    const PageCodecV1 = extern struct {
        abi_version: u32,
        ctx: ?*anyopaque,
        reserved_space: u8,
        codec_id: [16]u8,
        destroy: PageCodecDestroy,
        probe_header: PageCodecProbeHeader,
        decode_page: PageCodecTransform,
        encode_page: PageCodecTransform,
    };
    const DatabaseConfig = extern struct {
        async_io: u64,
        path: [*c]const u8,
        experimental_features: [*c]const u8,
        vfs: [*c]const u8,
        encryption_cipher: [*c]const u8,
        encryption_hexkey: [*c]const u8,
        page_codec: [*c]const PageCodecV1,
        open_flags: u32,
    };

    try expectLayout(raw.turso_slice_ref_t, SliceRef);
    try expectLayout(raw.turso_extension_text_t, ExtensionText);
    try expectLayout(raw.turso_extension_blob_t, ExtensionBlob);
    try expectLayout(raw.turso_extension_error_t, ExtensionError);
    try expectLayout(raw.turso_extension_value_data_t, ExtensionValueData);
    try expectLayout(raw.turso_value_t, ExtensionValue);
    try expectLayout(raw.turso_agg_ctx_t, AggregateContext);
    try expectLayout(raw.turso_log_t, Log);
    try expectLayout(raw.turso_page_codec_header_info_t, PageCodecHeaderInfo);
    try expectLayout(raw.turso_page_codec_v1_t, PageCodecV1);
    try std.testing.expectEqual(@offsetOf(ExtensionText, "text"), @offsetOf(raw.turso_extension_text_t, "text"));
    try std.testing.expectEqual(@offsetOf(ExtensionText, "len"), @offsetOf(raw.turso_extension_text_t, "len"));
    try std.testing.expectEqual(@offsetOf(ExtensionError, "message"), @offsetOf(raw.turso_extension_error_t, "message"));
    try std.testing.expectEqual(@offsetOf(ExtensionValue, "value"), @offsetOf(raw.turso_value_t, "value"));
    try std.testing.expectEqual(@offsetOf(Log, "timestamp"), @offsetOf(raw.turso_log_t, "timestamp"));
    try std.testing.expectEqual(@offsetOf(Log, "level"), @offsetOf(raw.turso_log_t, "level"));
    try std.testing.expectEqual(@offsetOf(PageCodecV1, "ctx"), @offsetOf(raw.turso_page_codec_v1_t, "ctx"));
    try std.testing.expectEqual(@offsetOf(PageCodecV1, "codec_id"), @offsetOf(raw.turso_page_codec_v1_t, "codec_id"));
    try std.testing.expectEqual(@offsetOf(PageCodecV1, "encode_page"), @offsetOf(raw.turso_page_codec_v1_t, "encode_page"));
    try std.testing.expectEqual(@sizeOf(DatabaseConfig), @sizeOf(raw.turso_database_config_t));
    try std.testing.expectEqual(@alignOf(DatabaseConfig), @alignOf(raw.turso_database_config_t));
    try std.testing.expectEqual(@offsetOf(DatabaseConfig, "async_io"), @offsetOf(raw.turso_database_config_t, "async_io"));
    try std.testing.expectEqual(@offsetOf(DatabaseConfig, "encryption_hexkey"), @offsetOf(raw.turso_database_config_t, "encryption_hexkey"));
    try std.testing.expectEqual(@offsetOf(DatabaseConfig, "page_codec"), @offsetOf(raw.turso_database_config_t, "page_codec"));
    try std.testing.expectEqual(@offsetOf(DatabaseConfig, "open_flags"), @offsetOf(raw.turso_database_config_t, "open_flags"));
}

test "independent C probe agrees with every public base struct layout" {
    try expectProbe(raw.turso_slice_ref_t, turso_zig_probe_size_slice_ref, turso_zig_probe_align_slice_ref);
    try expectProbe(raw.turso_extension_text_t, turso_zig_probe_size_extension_text, turso_zig_probe_align_extension_text);
    try expectProbe(raw.turso_extension_blob_t, turso_zig_probe_size_extension_blob, turso_zig_probe_align_extension_blob);
    try expectProbe(raw.turso_extension_error_t, turso_zig_probe_size_extension_error, turso_zig_probe_align_extension_error);
    try expectProbe(raw.turso_extension_value_data_t, turso_zig_probe_size_extension_value_data, turso_zig_probe_align_extension_value_data);
    try expectProbe(raw.turso_value_t, turso_zig_probe_size_value, turso_zig_probe_align_value);
    try expectProbe(raw.turso_agg_ctx_t, turso_zig_probe_size_agg_ctx, turso_zig_probe_align_agg_ctx);
    try expectProbe(raw.turso_log_t, turso_zig_probe_size_log, turso_zig_probe_align_log);
    try expectProbe(raw.turso_config_t, turso_zig_probe_size_config, turso_zig_probe_align_config);
    try expectProbe(raw.turso_page_codec_header_info_t, turso_zig_probe_size_page_codec_header_info, turso_zig_probe_align_page_codec_header_info);
    try expectProbe(raw.turso_page_codec_v1_t, turso_zig_probe_size_page_codec_v1, turso_zig_probe_align_page_codec_v1);
    try expectProbe(raw.turso_database_config_t, turso_zig_probe_size_database_config, turso_zig_probe_align_database_config);

    try expectOffset(raw.turso_slice_ref_t, "ptr", turso_zig_probe_offset_slice_ref_ptr);
    try expectOffset(raw.turso_slice_ref_t, "len", turso_zig_probe_offset_slice_ref_len);
    try expectOffset(raw.turso_extension_text_t, "subtype", turso_zig_probe_offset_extension_text_subtype);
    try expectOffset(raw.turso_extension_text_t, "text", turso_zig_probe_offset_extension_text_text);
    try expectOffset(raw.turso_extension_text_t, "len", turso_zig_probe_offset_extension_text_len);
    try expectOffset(raw.turso_extension_blob_t, "data", turso_zig_probe_offset_extension_blob_data);
    try expectOffset(raw.turso_extension_blob_t, "size", turso_zig_probe_offset_extension_blob_size);
    try expectOffset(raw.turso_extension_error_t, "code", turso_zig_probe_offset_extension_error_code);
    try expectOffset(raw.turso_extension_error_t, "message", turso_zig_probe_offset_extension_error_message);
    try expectOffset(raw.turso_value_t, "value_type", turso_zig_probe_offset_value_value_type);
    try expectOffset(raw.turso_value_t, "value", turso_zig_probe_offset_value_value);
    try expectOffset(raw.turso_agg_ctx_t, "state", turso_zig_probe_offset_agg_ctx_state);
    try expectOffset(raw.turso_log_t, "message", turso_zig_probe_offset_log_message);
    try expectOffset(raw.turso_log_t, "target", turso_zig_probe_offset_log_target);
    try expectOffset(raw.turso_log_t, "file", turso_zig_probe_offset_log_file);
    try expectOffset(raw.turso_log_t, "timestamp", turso_zig_probe_offset_log_timestamp);
    try expectOffset(raw.turso_log_t, "line", turso_zig_probe_offset_log_line);
    try expectOffset(raw.turso_log_t, "level", turso_zig_probe_offset_log_level);
    try expectOffset(raw.turso_config_t, "logger", turso_zig_probe_offset_config_logger);
    try expectOffset(raw.turso_config_t, "log_level", turso_zig_probe_offset_config_log_level);
    try expectOffset(raw.turso_page_codec_header_info_t, "page_size", turso_zig_probe_offset_page_codec_header_info_page_size);
    try expectOffset(raw.turso_page_codec_header_info_t, "reserved_space", turso_zig_probe_offset_page_codec_header_info_reserved_space);
    try expectOffset(raw.turso_page_codec_header_info_t, "is_supported", turso_zig_probe_offset_page_codec_header_info_is_supported);
    try expectOffset(raw.turso_page_codec_v1_t, "abi_version", turso_zig_probe_offset_page_codec_v1_abi_version);
    try expectOffset(raw.turso_page_codec_v1_t, "ctx", turso_zig_probe_offset_page_codec_v1_ctx);
    try expectOffset(raw.turso_page_codec_v1_t, "reserved_space", turso_zig_probe_offset_page_codec_v1_reserved_space);
    try expectOffset(raw.turso_page_codec_v1_t, "codec_id", turso_zig_probe_offset_page_codec_v1_codec_id);
    try expectOffset(raw.turso_page_codec_v1_t, "destroy", turso_zig_probe_offset_page_codec_v1_destroy);
    try expectOffset(raw.turso_page_codec_v1_t, "probe_header", turso_zig_probe_offset_page_codec_v1_probe_header);
    try expectOffset(raw.turso_page_codec_v1_t, "decode_page", turso_zig_probe_offset_page_codec_v1_decode_page);
    try expectOffset(raw.turso_page_codec_v1_t, "encode_page", turso_zig_probe_offset_page_codec_v1_encode_page);
    try expectOffset(raw.turso_database_config_t, "async_io", turso_zig_probe_offset_database_config_async_io);
    try expectOffset(raw.turso_database_config_t, "path", turso_zig_probe_offset_database_config_path);
    try expectOffset(raw.turso_database_config_t, "experimental_features", turso_zig_probe_offset_database_config_experimental_features);
    try expectOffset(raw.turso_database_config_t, "vfs", turso_zig_probe_offset_database_config_vfs);
    try expectOffset(raw.turso_database_config_t, "encryption_cipher", turso_zig_probe_offset_database_config_encryption_cipher);
    try expectOffset(raw.turso_database_config_t, "encryption_hexkey", turso_zig_probe_offset_database_config_encryption_hexkey);
    try expectOffset(raw.turso_database_config_t, "page_codec", turso_zig_probe_offset_database_config_page_codec);
    try expectOffset(raw.turso_database_config_t, "open_flags", turso_zig_probe_offset_database_config_open_flags);
    try std.testing.expectEqual(@as(c_int, 1), turso_zig_probe_callback_signatures());
}

test "all base SDK entry points retain function arity and C calling convention" {
    comptime {
        assertCFunctionPointer(raw.turso_context_destructor_t, 1);
        assertCFunctionPointer(raw.turso_value_destructor_t, 1);
        assertCFunctionPointer(raw.turso_scalar_function_t, 5);
        assertCFunctionPointer(raw.turso_aggregate_init_function_t, 1);
        assertCFunctionPointer(raw.turso_aggregate_step_function_t, 4);
        assertCFunctionPointer(raw.turso_aggregate_final_function_t, 2);
        assertCFunctionPointer(raw.turso_collation_function_t, 5);
        assertCFunctionPointer(raw.turso_page_codec_probe_header_t, 5);
        assertCFunctionPointer(raw.turso_page_codec_transform_t, 8);
        assertCFunctionPointer(raw.turso_page_codec_destroy_t, 1);
        assertCFunction(raw.turso_version, 0);
        assertCFunction(raw.turso_setup, 2);
        assertCFunction(raw.turso_database_new, 3);
        assertCFunction(raw.turso_database_open, 2);
        assertCFunction(raw.turso_database_connect, 3);
        assertCFunction(raw.turso_connection_set_busy_timeout_ms, 2);
        assertCFunction(raw.turso_connection_get_autocommit, 1);
        assertCFunction(raw.turso_connection_last_insert_rowid, 1);
        assertCFunction(raw.turso_connection_register_scalar_function, 9);
        assertCFunction(raw.turso_connection_register_aggregate_function, 11);
        assertCFunction(raw.turso_connection_unregister_function, 3);
        assertCFunction(raw.turso_connection_register_collation, 6);
        assertCFunction(raw.turso_connection_unregister_collation, 3);
        assertCFunction(raw.turso_connection_enable_load_extension, 3);
        assertCFunction(raw.turso_connection_load_extension, 3);
        assertCFunction(raw.turso_connection_prepare_single, 4);
        assertCFunction(raw.turso_connection_prepare_first, 5);
        assertCFunction(raw.turso_connection_close, 2);
        assertCFunction(raw.turso_statement_execute, 3);
        assertCFunction(raw.turso_statement_step, 2);
        assertCFunction(raw.turso_statement_run_io, 2);
        assertCFunction(raw.turso_statement_reset, 2);
        assertCFunction(raw.turso_statement_finalize, 2);
        assertCFunction(raw.turso_statement_n_change, 1);
        assertCFunction(raw.turso_statement_column_count, 1);
        assertCFunction(raw.turso_statement_column_name, 2);
        assertCFunction(raw.turso_statement_column_decltype, 2);
        assertCFunction(raw.turso_statement_column_declared_name, 2);
        assertCFunction(raw.turso_statement_column_array_dimensions, 2);
        assertCFunction(raw.turso_statement_column_base_type, 2);
        assertCFunction(raw.turso_statement_column_kind, 2);
        assertCFunction(raw.turso_statement_row_value_kind, 2);
        assertCFunction(raw.turso_statement_row_value_bytes_count, 2);
        assertCFunction(raw.turso_statement_row_value_bytes_ptr, 2);
        assertCFunction(raw.turso_statement_row_value_int, 2);
        assertCFunction(raw.turso_statement_row_value_double, 2);
        assertCFunction(raw.turso_statement_named_position, 2);
        assertCFunction(raw.turso_statement_parameters_count, 1);
        assertCFunction(raw.turso_statement_parameter_name, 2);
        assertCFunction(raw.turso_statement_bind_positional_null, 2);
        assertCFunction(raw.turso_statement_bind_positional_int, 3);
        assertCFunction(raw.turso_statement_bind_positional_double, 3);
        assertCFunction(raw.turso_statement_bind_positional_blob, 4);
        assertCFunction(raw.turso_statement_bind_positional_text, 4);
        assertCFunction(raw.turso_str_deinit, 1);
        assertCFunction(raw.turso_database_deinit, 1);
        assertCFunction(raw.turso_connection_deinit, 1);
        assertCFunction(raw.turso_statement_deinit, 1);
    }
}

test "raw ABI executes SELECT 1" {
    var error_message: [*c]const u8 = null;
    const config = raw.turso_database_config_t{
        .async_io = 0,
        .path = ":memory:",
        .experimental_features = null,
        .vfs = null,
        .encryption_cipher = null,
        .encryption_hexkey = null,
        .page_codec = null,
        .open_flags = raw.TURSO_DATABASE_OPEN_DEFAULT,
    };

    var database: ?*const raw.turso_database_t = null;
    try expectStatus(raw.TURSO_OK, raw.turso_database_new(&config, &database, &error_message), error_message);
    defer raw.turso_database_deinit(database);

    error_message = null;
    try expectStatus(raw.TURSO_OK, raw.turso_database_open(database, &error_message), error_message);

    var connection: ?*raw.turso_connection_t = null;
    error_message = null;
    try expectStatus(raw.TURSO_OK, raw.turso_database_connect(database, &connection, &error_message), error_message);
    defer raw.turso_connection_deinit(connection);

    var statement: ?*raw.turso_statement_t = null;
    error_message = null;
    try expectStatus(raw.TURSO_OK, raw.turso_connection_prepare_single(connection, "SELECT 1", &statement, &error_message), error_message);
    defer raw.turso_statement_deinit(statement);

    error_message = null;
    try expectStatus(raw.TURSO_ROW, raw.turso_statement_step(statement, &error_message), error_message);
    try std.testing.expectEqual(@as(raw.turso_type_t, raw.TURSO_TYPE_INTEGER), raw.turso_statement_row_value_kind(statement, 0));
    try std.testing.expectEqual(@as(i64, 1), raw.turso_statement_row_value_int(statement, 0));

    error_message = null;
    try expectStatus(raw.TURSO_DONE, raw.turso_statement_step(statement, &error_message), error_message);

    error_message = null;
    try expectStatus(raw.TURSO_DONE, raw.turso_statement_finalize(statement, &error_message), error_message);
}

fn expectStatus(expected: raw.turso_status_code_t, actual: raw.turso_status_code_t, error_message: [*c]const u8) !void {
    if (actual == expected) return;
    if (error_message != null) {
        defer raw.turso_str_deinit(error_message);
        std.debug.print("unexpected Turso status {d}; expected {d}: {s}\n", .{ actual, expected, error_message });
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
    if (info.param_types.len != parameter_count) @compileError("pinned SDK Kit function arity changed");
    if (std.meta.activeTag(info.attrs.@"callconv") != std.meta.activeTag(std.builtin.CallingConvention.c)) {
        @compileError("SDK Kit declaration lost the C calling convention");
    }
}

fn assertCFunctionPointer(comptime Pointer: type, comptime parameter_count: usize) void {
    const optional_info = @typeInfo(Pointer).optional;
    const pointer_info = @typeInfo(optional_info.child).pointer;
    const function_info = @typeInfo(pointer_info.child).@"fn";
    if (function_info.param_types.len != parameter_count) @compileError("pinned SDK Kit callback arity changed");
    if (std.meta.activeTag(function_info.attrs.@"callconv") != std.meta.activeTag(std.builtin.CallingConvention.c)) {
        @compileError("SDK Kit callback declaration lost the C calling convention");
    }
}
