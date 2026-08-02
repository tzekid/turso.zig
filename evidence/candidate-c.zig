const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const ptrdiff_t = c_long;
pub const wchar_t = c_int;
pub const max_align_t = extern struct {
    __aro_max_align_ll: c_longlong = 0,
    __aro_max_align_ld: c_longdouble = 0,
};
pub const int_least64_t = i64;
pub const uint_least64_t = u64;
pub const int_fast64_t = i64;
pub const uint_fast64_t = u64;
pub const int_least32_t = i32;
pub const uint_least32_t = u32;
pub const int_fast32_t = i32;
pub const uint_fast32_t = u32;
pub const int_least16_t = i16;
pub const uint_least16_t = u16;
pub const int_fast16_t = i16;
pub const uint_fast16_t = u16;
pub const int_least8_t = i8;
pub const uint_least8_t = u8;
pub const int_fast8_t = i8;
pub const uint_fast8_t = u8;
pub const intmax_t = c_long;
pub const uintmax_t = c_ulong;
pub const turso_slice_ref_t = extern struct {
    ptr: ?*const anyopaque = null,
    len: usize = 0,
};
pub const TURSO_OK: c_int = 0;
pub const TURSO_DONE: c_int = 1;
pub const TURSO_ROW: c_int = 2;
pub const TURSO_IO: c_int = 3;
pub const TURSO_BUSY: c_int = 4;
pub const TURSO_INTERRUPT: c_int = 5;
pub const TURSO_BUSY_SNAPSHOT: c_int = 6;
pub const TURSO_ERROR: c_int = 127;
pub const TURSO_MISUSE: c_int = 128;
pub const TURSO_CONSTRAINT: c_int = 129;
pub const TURSO_READONLY: c_int = 130;
pub const TURSO_DATABASE_FULL: c_int = 131;
pub const TURSO_NOTADB: c_int = 132;
pub const TURSO_CORRUPT: c_int = 133;
pub const TURSO_IOERR: c_int = 134;
pub const turso_status_code_t = c_uint;
pub const TURSO_TYPE_UNKNOWN: c_int = 0;
pub const TURSO_TYPE_INTEGER: c_int = 1;
pub const TURSO_TYPE_REAL: c_int = 2;
pub const TURSO_TYPE_TEXT: c_int = 3;
pub const TURSO_TYPE_BLOB: c_int = 4;
pub const TURSO_TYPE_NULL: c_int = 5;
pub const turso_type_t = c_uint;
pub const TURSO_EXTENSION_VALUE_NULL: c_int = 0;
pub const TURSO_EXTENSION_VALUE_INTEGER: c_int = 1;
pub const TURSO_EXTENSION_VALUE_FLOAT: c_int = 2;
pub const TURSO_EXTENSION_VALUE_TEXT: c_int = 3;
pub const TURSO_EXTENSION_VALUE_BLOB: c_int = 4;
pub const TURSO_EXTENSION_VALUE_ERROR: c_int = 5;
pub const turso_extension_value_type_t = c_uint;
pub const TURSO_EXTENSION_RESULT_OK: c_int = 0;
pub const TURSO_EXTENSION_RESULT_ERROR: c_int = 1;
pub const TURSO_EXTENSION_RESULT_INVALID_ARGS: c_int = 2;
pub const TURSO_EXTENSION_RESULT_UNKNOWN: c_int = 3;
pub const TURSO_EXTENSION_RESULT_OOM: c_int = 4;
pub const TURSO_EXTENSION_RESULT_CORRUPT: c_int = 5;
pub const TURSO_EXTENSION_RESULT_NOT_FOUND: c_int = 6;
pub const TURSO_EXTENSION_RESULT_ALREADY_EXISTS: c_int = 7;
pub const TURSO_EXTENSION_RESULT_PERMISSION_DENIED: c_int = 8;
pub const TURSO_EXTENSION_RESULT_ABORTED: c_int = 9;
pub const TURSO_EXTENSION_RESULT_OUT_OF_RANGE: c_int = 10;
pub const TURSO_EXTENSION_RESULT_UNIMPLEMENTED: c_int = 11;
pub const TURSO_EXTENSION_RESULT_INTERNAL: c_int = 12;
pub const TURSO_EXTENSION_RESULT_UNAVAILABLE: c_int = 13;
pub const TURSO_EXTENSION_RESULT_CUSTOM_ERROR: c_int = 14;
pub const TURSO_EXTENSION_RESULT_EOF: c_int = 15;
pub const TURSO_EXTENSION_RESULT_READ_ONLY: c_int = 16;
pub const TURSO_EXTENSION_RESULT_ROWID: c_int = 17;
pub const TURSO_EXTENSION_RESULT_ROW: c_int = 18;
pub const TURSO_EXTENSION_RESULT_INTERRUPT: c_int = 19;
pub const TURSO_EXTENSION_RESULT_BUSY: c_int = 20;
pub const TURSO_EXTENSION_RESULT_CONSTRAINT_VIOLATION: c_int = 21;
pub const turso_extension_result_code_t = c_uint;
pub const TURSO_EXTENSION_TEXT_TEXT: c_int = 0;
pub const TURSO_EXTENSION_TEXT_JSON: c_int = 1;
pub const turso_extension_text_subtype_t = c_uint;
pub const turso_extension_text_t = extern struct {
    subtype: turso_extension_text_subtype_t = @import("std").mem.zeroes(turso_extension_text_subtype_t),
    text: [*c]const u8 = null,
    len: u32 = 0,
};
pub const turso_extension_blob_t = extern struct {
    data: [*c]const u8 = null,
    size: u64 = 0,
};
pub const turso_extension_error_t = extern struct {
    code: turso_extension_result_code_t = @import("std").mem.zeroes(turso_extension_result_code_t),
    message: [*c]turso_extension_text_t = null,
};
pub const turso_extension_value_data_t = extern union {
    int_value: i64,
    float_value: f64,
    text: [*c]const turso_extension_text_t,
    blob: [*c]const turso_extension_blob_t,
    @"error": [*c]const turso_extension_error_t,
};
pub const turso_value_t = extern struct {
    value_type: turso_extension_value_type_t = @import("std").mem.zeroes(turso_extension_value_type_t),
    value: turso_extension_value_data_t = @import("std").mem.zeroes(turso_extension_value_data_t),
};
pub const turso_agg_ctx_t = extern struct {
    state: ?*anyopaque = null,
};
pub const turso_context_destructor_t = ?*const fn (context: usize) callconv(.c) void;
pub const turso_value_destructor_t = ?*const fn (result: [*c]turso_value_t) callconv(.c) void;
pub const turso_scalar_function_t = ?*const fn (context: usize, argc: i32, argv: [*c]const turso_value_t, context_destructor: turso_context_destructor_t, value_destructor: turso_value_destructor_t) callconv(.c) turso_value_t;
pub const turso_aggregate_init_function_t = ?*const fn (context: usize) callconv(.c) [*c]turso_agg_ctx_t;
pub const turso_aggregate_step_function_t = ?*const fn (context: usize, aggregate_context: [*c]turso_agg_ctx_t, argc: i32, argv: [*c]const turso_value_t) callconv(.c) turso_value_t;
pub const turso_aggregate_final_function_t = ?*const fn (context: usize, aggregate_context: [*c]turso_agg_ctx_t) callconv(.c) turso_value_t;
pub const turso_collation_function_t = ?*const fn (context: usize, left_ptr: [*c]const u8, left_len: usize, right_ptr: [*c]const u8, right_len: usize) callconv(.c) i32;
pub const TURSO_TRACING_LEVEL_ERROR: c_int = 1;
pub const TURSO_TRACING_LEVEL_WARN: c_int = 2;
pub const TURSO_TRACING_LEVEL_INFO: c_int = 3;
pub const TURSO_TRACING_LEVEL_DEBUG: c_int = 4;
pub const TURSO_TRACING_LEVEL_TRACE: c_int = 5;
pub const turso_tracing_level_t = c_uint;
pub const struct_turso_database = opaque {
    pub const turso_database_open = __root.turso_database_open;
    pub const turso_database_connect = __root.turso_database_connect;
    pub const turso_database_deinit = __root.turso_database_deinit;
    pub const open = __root.turso_database_open;
    pub const connect = __root.turso_database_connect;
    pub const deinit = __root.turso_database_deinit;
};
pub const turso_database_t = struct_turso_database;
pub const struct_turso_connection = opaque {
    pub const turso_connection_set_busy_timeout_ms = __root.turso_connection_set_busy_timeout_ms;
    pub const turso_connection_get_autocommit = __root.turso_connection_get_autocommit;
    pub const turso_connection_last_insert_rowid = __root.turso_connection_last_insert_rowid;
    pub const turso_connection_register_scalar_function = __root.turso_connection_register_scalar_function;
    pub const turso_connection_register_aggregate_function = __root.turso_connection_register_aggregate_function;
    pub const turso_connection_unregister_function = __root.turso_connection_unregister_function;
    pub const turso_connection_register_collation = __root.turso_connection_register_collation;
    pub const turso_connection_unregister_collation = __root.turso_connection_unregister_collation;
    pub const turso_connection_enable_load_extension = __root.turso_connection_enable_load_extension;
    pub const turso_connection_load_extension = __root.turso_connection_load_extension;
    pub const turso_connection_prepare_single = __root.turso_connection_prepare_single;
    pub const turso_connection_prepare_first = __root.turso_connection_prepare_first;
    pub const turso_connection_close = __root.turso_connection_close;
    pub const turso_connection_deinit = __root.turso_connection_deinit;
    pub const set_busy_timeout_ms = __root.turso_connection_set_busy_timeout_ms;
    pub const get_autocommit = __root.turso_connection_get_autocommit;
    pub const last_insert_rowid = __root.turso_connection_last_insert_rowid;
    pub const register_scalar_function = __root.turso_connection_register_scalar_function;
    pub const register_aggregate_function = __root.turso_connection_register_aggregate_function;
    pub const unregister_function = __root.turso_connection_unregister_function;
    pub const register_collation = __root.turso_connection_register_collation;
    pub const unregister_collation = __root.turso_connection_unregister_collation;
    pub const enable_load_extension = __root.turso_connection_enable_load_extension;
    pub const load_extension = __root.turso_connection_load_extension;
    pub const prepare_single = __root.turso_connection_prepare_single;
    pub const prepare_first = __root.turso_connection_prepare_first;
    pub const close = __root.turso_connection_close;
    pub const deinit = __root.turso_connection_deinit;
};
pub const turso_connection_t = struct_turso_connection;
pub const struct_turso_statement = opaque {
    pub const turso_statement_execute = __root.turso_statement_execute;
    pub const turso_statement_step = __root.turso_statement_step;
    pub const turso_statement_run_io = __root.turso_statement_run_io;
    pub const turso_statement_reset = __root.turso_statement_reset;
    pub const turso_statement_finalize = __root.turso_statement_finalize;
    pub const turso_statement_n_change = __root.turso_statement_n_change;
    pub const turso_statement_column_count = __root.turso_statement_column_count;
    pub const turso_statement_column_name = __root.turso_statement_column_name;
    pub const turso_statement_column_decltype = __root.turso_statement_column_decltype;
    pub const turso_statement_column_declared_name = __root.turso_statement_column_declared_name;
    pub const turso_statement_column_array_dimensions = __root.turso_statement_column_array_dimensions;
    pub const turso_statement_column_base_type = __root.turso_statement_column_base_type;
    pub const turso_statement_column_kind = __root.turso_statement_column_kind;
    pub const turso_statement_row_value_kind = __root.turso_statement_row_value_kind;
    pub const turso_statement_row_value_bytes_count = __root.turso_statement_row_value_bytes_count;
    pub const turso_statement_row_value_bytes_ptr = __root.turso_statement_row_value_bytes_ptr;
    pub const turso_statement_row_value_int = __root.turso_statement_row_value_int;
    pub const turso_statement_row_value_double = __root.turso_statement_row_value_double;
    pub const turso_statement_named_position = __root.turso_statement_named_position;
    pub const turso_statement_parameters_count = __root.turso_statement_parameters_count;
    pub const turso_statement_parameter_name = __root.turso_statement_parameter_name;
    pub const turso_statement_bind_positional_null = __root.turso_statement_bind_positional_null;
    pub const turso_statement_bind_positional_int = __root.turso_statement_bind_positional_int;
    pub const turso_statement_bind_positional_double = __root.turso_statement_bind_positional_double;
    pub const turso_statement_bind_positional_blob = __root.turso_statement_bind_positional_blob;
    pub const turso_statement_bind_positional_text = __root.turso_statement_bind_positional_text;
    pub const turso_statement_deinit = __root.turso_statement_deinit;
    pub const execute = __root.turso_statement_execute;
    pub const step = __root.turso_statement_step;
    pub const run_io = __root.turso_statement_run_io;
    pub const reset = __root.turso_statement_reset;
    pub const finalize = __root.turso_statement_finalize;
    pub const n_change = __root.turso_statement_n_change;
    pub const column_count = __root.turso_statement_column_count;
    pub const column_name = __root.turso_statement_column_name;
    pub const column_decltype = __root.turso_statement_column_decltype;
    pub const column_declared_name = __root.turso_statement_column_declared_name;
    pub const column_array_dimensions = __root.turso_statement_column_array_dimensions;
    pub const column_base_type = __root.turso_statement_column_base_type;
    pub const column_kind = __root.turso_statement_column_kind;
    pub const row_value_kind = __root.turso_statement_row_value_kind;
    pub const row_value_bytes_count = __root.turso_statement_row_value_bytes_count;
    pub const row_value_bytes_ptr = __root.turso_statement_row_value_bytes_ptr;
    pub const row_value_int = __root.turso_statement_row_value_int;
    pub const row_value_double = __root.turso_statement_row_value_double;
    pub const named_position = __root.turso_statement_named_position;
    pub const parameters_count = __root.turso_statement_parameters_count;
    pub const parameter_name = __root.turso_statement_parameter_name;
    pub const bind_positional_null = __root.turso_statement_bind_positional_null;
    pub const bind_positional_int = __root.turso_statement_bind_positional_int;
    pub const bind_positional_double = __root.turso_statement_bind_positional_double;
    pub const bind_positional_blob = __root.turso_statement_bind_positional_blob;
    pub const bind_positional_text = __root.turso_statement_bind_positional_text;
    pub const deinit = __root.turso_statement_deinit;
};
pub const turso_statement_t = struct_turso_statement;
pub extern fn turso_version(...) [*c]const u8;
pub const turso_log_t = extern struct {
    message: [*c]const u8 = null,
    target: [*c]const u8 = null,
    file: [*c]const u8 = null,
    timestamp: u64 = 0,
    line: usize = 0,
    level: turso_tracing_level_t = @import("std").mem.zeroes(turso_tracing_level_t),
};
pub const turso_config_t = extern struct {
    logger: ?*const fn (log: [*c]const turso_log_t) callconv(.c) void = null,
    log_level: [*c]const u8 = null,
    pub const turso_setup = __root.turso_setup;
    pub const setup = __root.turso_setup;
};
pub const turso_database_config_t = extern struct {
    async_io: u64 = 0,
    path: [*c]const u8 = null,
    experimental_features: [*c]const u8 = null,
    vfs: [*c]const u8 = null,
    encryption_cipher: [*c]const u8 = null,
    encryption_hexkey: [*c]const u8 = null,
    pub const turso_database_new = __root.turso_database_new;
    pub const new = __root.turso_database_new;
};
pub extern fn turso_setup(config: [*c]const turso_config_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_database_new(config: [*c]const turso_database_config_t, database: [*c]?*const turso_database_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_database_open(database: ?*const turso_database_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_database_connect(self: ?*const turso_database_t, connection: [*c]?*turso_connection_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_set_busy_timeout_ms(self: ?*const turso_connection_t, timeout_ms: i64) void;
pub extern fn turso_connection_get_autocommit(self: ?*const turso_connection_t) bool;
pub extern fn turso_connection_last_insert_rowid(self: ?*const turso_connection_t) i64;
pub extern fn turso_connection_register_scalar_function(self: ?*const turso_connection_t, name: [*c]const u8, argc: i32, deterministic: bool, context: usize, callback: turso_scalar_function_t, context_destructor: turso_context_destructor_t, value_destructor: turso_value_destructor_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_register_aggregate_function(self: ?*const turso_connection_t, name: [*c]const u8, argc: i32, context: usize, init: turso_aggregate_init_function_t, step: turso_aggregate_step_function_t, finalize: turso_aggregate_final_function_t, context_destructor: turso_context_destructor_t, aggregate_destructor: turso_context_destructor_t, value_destructor: turso_value_destructor_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_unregister_function(self: ?*const turso_connection_t, name: [*c]const u8, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_register_collation(self: ?*const turso_connection_t, name: [*c]const u8, context: usize, callback: turso_collation_function_t, context_destructor: turso_context_destructor_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_unregister_collation(self: ?*const turso_connection_t, name: [*c]const u8, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_enable_load_extension(self: ?*const turso_connection_t, enabled: bool, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_load_extension(self: ?*const turso_connection_t, path: [*c]const u8, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_prepare_single(self: ?*const turso_connection_t, sql: [*c]const u8, statement: [*c]?*turso_statement_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_prepare_first(self: ?*const turso_connection_t, sql: [*c]const u8, statement: [*c]?*turso_statement_t, tail_idx: [*c]usize, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_connection_close(self: ?*const turso_connection_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_execute(self: ?*const turso_statement_t, rows_changes: [*c]u64, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_step(self: ?*const turso_statement_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_run_io(self: ?*const turso_statement_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_reset(self: ?*const turso_statement_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_finalize(self: ?*const turso_statement_t, error_opt_out: [*c][*c]const u8) turso_status_code_t;
pub extern fn turso_statement_n_change(self: ?*const turso_statement_t) i64;
pub extern fn turso_statement_column_count(self: ?*const turso_statement_t) i64;
pub extern fn turso_statement_column_name(self: ?*const turso_statement_t, index: usize) [*c]const u8;
pub extern fn turso_statement_column_decltype(self: ?*const turso_statement_t, index: usize) [*c]const u8;
pub const TURSO_COLUMN_KIND_NONE: c_int = -1;
pub const TURSO_COLUMN_KIND_BUILTIN: c_int = 0;
pub const TURSO_COLUMN_KIND_CUSTOM: c_int = 1;
pub const TURSO_COLUMN_KIND_DOMAIN: c_int = 2;
pub const TURSO_COLUMN_KIND_STRUCT: c_int = 3;
pub const TURSO_COLUMN_KIND_UNION: c_int = 4;
pub const turso_column_kind_t = c_int;
pub extern fn turso_statement_column_declared_name(self: ?*const turso_statement_t, index: usize) [*c]const u8;
pub extern fn turso_statement_column_array_dimensions(self: ?*const turso_statement_t, index: usize) u32;
pub extern fn turso_statement_column_base_type(self: ?*const turso_statement_t, index: usize) [*c]const u8;
pub extern fn turso_statement_column_kind(self: ?*const turso_statement_t, index: usize) turso_column_kind_t;
pub extern fn turso_statement_row_value_kind(self: ?*const turso_statement_t, index: usize) turso_type_t;
pub extern fn turso_statement_row_value_bytes_count(self: ?*const turso_statement_t, index: usize) i64;
pub extern fn turso_statement_row_value_bytes_ptr(self: ?*const turso_statement_t, index: usize) [*c]const u8;
pub extern fn turso_statement_row_value_int(self: ?*const turso_statement_t, index: usize) i64;
pub extern fn turso_statement_row_value_double(self: ?*const turso_statement_t, index: usize) f64;
pub extern fn turso_statement_named_position(self: ?*const turso_statement_t, name: [*c]const u8) i64;
pub extern fn turso_statement_parameters_count(self: ?*const turso_statement_t) i64;
pub extern fn turso_statement_parameter_name(self: ?*const turso_statement_t, index: i64) [*c]const u8;
pub extern fn turso_statement_bind_positional_null(self: ?*const turso_statement_t, position: usize) turso_status_code_t;
pub extern fn turso_statement_bind_positional_int(self: ?*const turso_statement_t, position: usize, value: i64) turso_status_code_t;
pub extern fn turso_statement_bind_positional_double(self: ?*const turso_statement_t, position: usize, value: f64) turso_status_code_t;
pub extern fn turso_statement_bind_positional_blob(self: ?*const turso_statement_t, position: usize, ptr: [*c]const u8, len: usize) turso_status_code_t;
pub extern fn turso_statement_bind_positional_text(self: ?*const turso_statement_t, position: usize, ptr: [*c]const u8, len: usize) turso_status_code_t;
pub extern fn turso_str_deinit(self: [*c]const u8) void;
pub extern fn turso_database_deinit(self: ?*const turso_database_t) void;
pub extern fn turso_connection_deinit(self: ?*const turso_connection_t) void;
pub extern fn turso_statement_deinit(self: ?*const turso_statement_t) void;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 7);
pub const __GNUC_MINOR__ = @as(c_int, 1);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 0);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_GCC__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const linux = @as(c_int, 1);
pub const __linux = @as(c_int, 1);
pub const __linux__ = @as(c_int, 1);
pub const unix = @as(c_int, 1);
pub const __unix = @as(c_int, 1);
pub const __unix__ = @as(c_int, 1);
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`"); // <builtin>:33:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`"); // <builtin>:34:9
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __SSE4A__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __CLZERO__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __RDPRU__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __SIZEOF_FLOAT128__ = @as(c_int, 16);
pub const _LP64 = @as(c_int, 1);
pub const __LP64__ = @as(c_int, 1);
pub const __FLOAT128__ = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ELF__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __LONG_WIDTH__ = @as(c_int, 64);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 32);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 32);
pub const __INTMAX_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 10);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 8);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 4);
pub const __SIZEOF_WINT_T__ = @as(c_int, 4);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTPTR_TYPE__ = c_long;
pub const __UINTPTR_TYPE__ = c_ulong;
pub const __INTMAX_TYPE__ = c_long;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`"); // <builtin>:154:9
pub const __INTMAX_C = __helpers.L_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`"); // <builtin>:157:9
pub const __UINTMAX_C = __helpers.UL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_long;
pub const __SIZE_TYPE__ = c_ulong;
pub const __WCHAR_TYPE__ = c_int;
pub const __WINT_TYPE__ = c_uint;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_long;
pub const __INT64_FMTd__ = "ld";
pub const __INT64_FMTi__ = "li";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`"); // <builtin>:183:9
pub const __INT64_C = __helpers.L_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`"); // <builtin>:208:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulong;
pub const __UINT64_FMTo__ = "lo";
pub const __UINT64_FMTu__ = "lu";
pub const __UINT64_FMTx__ = "lx";
pub const __UINT64_FMTX__ = "lX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`"); // <builtin>:217:9
pub const __UINT64_C = __helpers.UL_SUFFIX;
pub const __UINT64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __INT64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_long;
pub const __INT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "ld";
pub const INT_LEAST64_FMTi__ = "li";
pub const __UINT_LEAST64_TYPE__ = c_ulong;
pub const __UINT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_LEAST64_FMTo__ = "lo";
pub const UINT_LEAST64_FMTu__ = "lu";
pub const UINT_LEAST64_FMTx__ = "lx";
pub const UINT_LEAST64_FMTX__ = "lX";
pub const __INT_FAST64_TYPE__ = c_long;
pub const __INT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "ld";
pub const INT_FAST64_FMTi__ = "li";
pub const __UINT_FAST64_TYPE__ = c_ulong;
pub const __UINT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_FAST64_FMTo__ = "lo";
pub const UINT_FAST64_FMTu__ = "lu";
pub const UINT_FAST64_FMTx__ = "lx";
pub const UINT_FAST64_FMTX__ = "lX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = "";
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = "";
pub const __FLT16_HAS_QUIET_NAN__ = "";
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const TURSO_H = "";
pub const @"bool" = bool;
pub const @"true" = @as(c_int, 1);
pub const @"false" = @as(c_int, 0);
pub const __bool_true_false_are_defined = @as(c_int, 1);
pub const __STDC_VERSION_STDDEF_H__ = @as(c_long, 202311);
pub const NULL = __helpers.cast(?*anyopaque, @as(c_int, 0));
pub const offsetof = @compileError("unable to translate macro: undefined identifier `__builtin_offsetof`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/compiler/aro/include/stddef.h:18:9
pub const __CLANG_STDINT_H = "";
pub const __int_least64_t = i64;
pub const __uint_least64_t = u64;
pub const __uint32_t_defined = "";
pub const __int_least32_t = i32;
pub const __uint_least32_t = u32;
pub const __int_least16_t = i16;
pub const __uint_least16_t = u16;
pub const __int_least8_t = i8;
pub const __uint_least8_t = u8;
pub const __int8_t_defined = "";
pub const __stdint_join3 = @compileError("unable to translate C expr: unexpected token '##'"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:291:9
pub const __intptr_t_defined = "";
pub const _INTPTR_T = "";
pub const _UINTPTR_T = "";
pub inline fn INT64_C(v: anytype) @TypeOf(__INT64_C(v)) {
    _ = &v;
    return __INT64_C(v);
}
pub inline fn UINT64_C(v: anytype) @TypeOf(__UINT64_C(v)) {
    _ = &v;
    return __UINT64_C(v);
}
pub inline fn INT32_C(v: anytype) @TypeOf(__INT32_C(v)) {
    _ = &v;
    return __INT32_C(v);
}
pub inline fn UINT32_C(v: anytype) @TypeOf(__UINT32_C(v)) {
    _ = &v;
    return __UINT32_C(v);
}
pub inline fn INT16_C(v: anytype) @TypeOf(__INT16_C(v)) {
    _ = &v;
    return __INT16_C(v);
}
pub inline fn UINT16_C(v: anytype) @TypeOf(__UINT16_C(v)) {
    _ = &v;
    return __UINT16_C(v);
}
pub inline fn INT8_C(v: anytype) @TypeOf(__INT8_C(v)) {
    _ = &v;
    return __INT8_C(v);
}
pub inline fn UINT8_C(v: anytype) @TypeOf(__UINT8_C(v)) {
    _ = &v;
    return __UINT8_C(v);
}
pub const INT64_MAX = INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal));
pub const INT64_MIN = -INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal)) - @as(c_int, 1);
pub const UINT64_MAX = UINT64_C(__helpers.promoteIntLiteral(c_int, 18446744073709551615, .decimal));
pub const __INT_LEAST64_MIN = INT64_MIN;
pub const __INT_LEAST64_MAX = INT64_MAX;
pub const __UINT_LEAST64_MAX = UINT64_MAX;
pub const INT_LEAST64_MIN = __INT_LEAST64_MIN;
pub const INT_LEAST64_MAX = __INT_LEAST64_MAX;
pub const UINT_LEAST64_MAX = __UINT_LEAST64_MAX;
pub const INT_FAST64_MIN = __INT_LEAST64_MIN;
pub const INT_FAST64_MAX = __INT_LEAST64_MAX;
pub const UINT_FAST64_MAX = __UINT_LEAST64_MAX;
pub const INT32_MAX = INT32_C(__helpers.promoteIntLiteral(c_int, 2147483647, .decimal));
pub const INT32_MIN = -INT32_C(__helpers.promoteIntLiteral(c_int, 2147483647, .decimal)) - @as(c_int, 1);
pub const UINT32_MAX = UINT32_C(__helpers.promoteIntLiteral(c_int, 4294967295, .decimal));
pub const __INT_LEAST32_MIN = INT32_MIN;
pub const __INT_LEAST32_MAX = INT32_MAX;
pub const __UINT_LEAST32_MAX = UINT32_MAX;
pub const INT_LEAST32_MIN = __INT_LEAST32_MIN;
pub const INT_LEAST32_MAX = __INT_LEAST32_MAX;
pub const UINT_LEAST32_MAX = __UINT_LEAST32_MAX;
pub const INT_FAST32_MIN = __INT_LEAST32_MIN;
pub const INT_FAST32_MAX = __INT_LEAST32_MAX;
pub const UINT_FAST32_MAX = __UINT_LEAST32_MAX;
pub const INT16_MAX = INT16_C(@as(c_int, 32767));
pub const INT16_MIN = -INT16_C(@as(c_int, 32767)) - @as(c_int, 1);
pub const UINT16_MAX = UINT16_C(__helpers.promoteIntLiteral(c_int, 65535, .decimal));
pub const __INT_LEAST16_MIN = INT16_MIN;
pub const __INT_LEAST16_MAX = INT16_MAX;
pub const __UINT_LEAST16_MAX = UINT16_MAX;
pub const INT_LEAST16_MIN = __INT_LEAST16_MIN;
pub const INT_LEAST16_MAX = __INT_LEAST16_MAX;
pub const UINT_LEAST16_MAX = __UINT_LEAST16_MAX;
pub const INT_FAST16_MIN = __INT_LEAST16_MIN;
pub const INT_FAST16_MAX = __INT_LEAST16_MAX;
pub const UINT_FAST16_MAX = __UINT_LEAST16_MAX;
pub const INT8_MAX = INT8_C(@as(c_int, 127));
pub const INT8_MIN = -INT8_C(@as(c_int, 127)) - @as(c_int, 1);
pub const UINT8_MAX = UINT8_C(@as(c_int, 255));
pub const __INT_LEAST8_MIN = INT8_MIN;
pub const __INT_LEAST8_MAX = INT8_MAX;
pub const __UINT_LEAST8_MAX = UINT8_MAX;
pub const INT_LEAST8_MIN = __INT_LEAST8_MIN;
pub const INT_LEAST8_MAX = __INT_LEAST8_MAX;
pub const UINT_LEAST8_MAX = __UINT_LEAST8_MAX;
pub const INT_FAST8_MIN = __INT_LEAST8_MIN;
pub const INT_FAST8_MAX = __INT_LEAST8_MAX;
pub const UINT_FAST8_MAX = __UINT_LEAST8_MAX;
pub const __INTN_MIN = @compileError("unable to translate macro: undefined identifier `INT`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:764:10
pub const __INTN_MAX = @compileError("unable to translate macro: undefined identifier `INT`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:765:10
pub const __UINTN_MAX = @compileError("unable to translate macro: undefined identifier `UINT`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:766:9
pub const __INTN_C = @compileError("unable to translate macro: undefined identifier `INT`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:767:10
pub const __UINTN_C = @compileError("unable to translate macro: undefined identifier `UINT`"); // /home/runner/work/_temp/38b19bc2-f4aa-4538-8844-bb530a8f83ac/zig-x86_64-linux-0.17.0-dev.1509+bb296ab9b/lib/include/stdint.h:768:9
pub const INTPTR_MIN = -__INTPTR_MAX__ - @as(c_int, 1);
pub const INTPTR_MAX = __INTPTR_MAX__;
pub const UINTPTR_MAX = __UINTPTR_MAX__;
pub const PTRDIFF_MIN = -__PTRDIFF_MAX__ - @as(c_int, 1);
pub const PTRDIFF_MAX = __PTRDIFF_MAX__;
pub const SIZE_MAX = __SIZE_MAX__;
pub const INTMAX_MIN = -__INTMAX_MAX__ - @as(c_int, 1);
pub const INTMAX_MAX = __INTMAX_MAX__;
pub const UINTMAX_MAX = __UINTMAX_MAX__;
pub const SIG_ATOMIC_MIN = __INTN_MIN(__SIG_ATOMIC_WIDTH__);
pub const SIG_ATOMIC_MAX = __INTN_MAX(__SIG_ATOMIC_WIDTH__);
pub const WINT_MIN = __UINTN_C(__WINT_WIDTH__, @as(c_int, 0));
pub const WINT_MAX = __UINTN_MAX(__WINT_WIDTH__);
pub const WCHAR_MAX = __WCHAR_MAX__;
pub const WCHAR_MIN = __INTN_MIN(__WCHAR_WIDTH__);
pub inline fn INTMAX_C(v: anytype) @TypeOf(__INTMAX_C(v)) {
    _ = &v;
    return __INTMAX_C(v);
}
pub inline fn UINTMAX_C(v: anytype) @TypeOf(__UINTMAX_C(v)) {
    _ = &v;
    return __UINTMAX_C(v);
}
pub const turso_database = struct_turso_database;
pub const turso_connection = struct_turso_connection;
pub const turso_statement = struct_turso_statement;
