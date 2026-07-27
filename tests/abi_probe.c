#include "turso.h"

#include <stddef.h>

#define PROBE_LAYOUT(name, type)                 \
    size_t turso_zig_probe_size_##name(void)     \
    {                                             \
        return sizeof(type);                      \
    }                                             \
    size_t turso_zig_probe_align_##name(void)    \
    {                                             \
        return _Alignof(type);                    \
    }

#define PROBE_OFFSET(name, type, field)              \
    size_t turso_zig_probe_offset_##name##_##field(void) \
    {                                                 \
        return offsetof(type, field);                 \
    }

#define CHECK_FUNCTION(name, return_type, ...)                              \
    typedef return_type (*name##_expected_t)(__VA_ARGS__);                  \
    _Static_assert(_Generic(&(name), name##_expected_t: 1, default: 0),     \
                   "C function signature changed: " #name)

CHECK_FUNCTION(turso_version, const char *, void);
CHECK_FUNCTION(turso_setup, turso_status_code_t, const turso_config_t *, const char **);
CHECK_FUNCTION(turso_database_new, turso_status_code_t, const turso_database_config_t *, const turso_database_t **, const char **);
CHECK_FUNCTION(turso_database_open, turso_status_code_t, const turso_database_t *, const char **);
CHECK_FUNCTION(turso_database_connect, turso_status_code_t, const turso_database_t *, turso_connection_t **, const char **);
CHECK_FUNCTION(turso_connection_set_busy_timeout_ms, void, const turso_connection_t *, int64_t);
CHECK_FUNCTION(turso_connection_get_autocommit, bool, const turso_connection_t *);
CHECK_FUNCTION(turso_connection_last_insert_rowid, int64_t, const turso_connection_t *);
CHECK_FUNCTION(turso_connection_register_scalar_function, turso_status_code_t, const turso_connection_t *, const char *, int32_t, bool, uintptr_t, turso_scalar_function_t, turso_context_destructor_t, turso_value_destructor_t, const char **);
CHECK_FUNCTION(turso_connection_register_aggregate_function, turso_status_code_t, const turso_connection_t *, const char *, int32_t, uintptr_t, turso_aggregate_init_function_t, turso_aggregate_step_function_t, turso_aggregate_final_function_t, turso_context_destructor_t, turso_context_destructor_t, turso_value_destructor_t, const char **);
CHECK_FUNCTION(turso_connection_unregister_function, turso_status_code_t, const turso_connection_t *, const char *, const char **);
CHECK_FUNCTION(turso_connection_register_collation, turso_status_code_t, const turso_connection_t *, const char *, uintptr_t, turso_collation_function_t, turso_context_destructor_t, const char **);
CHECK_FUNCTION(turso_connection_unregister_collation, turso_status_code_t, const turso_connection_t *, const char *, const char **);
CHECK_FUNCTION(turso_connection_enable_load_extension, turso_status_code_t, const turso_connection_t *, bool, const char **);
CHECK_FUNCTION(turso_connection_load_extension, turso_status_code_t, const turso_connection_t *, const char *, const char **);
CHECK_FUNCTION(turso_connection_prepare_single, turso_status_code_t, const turso_connection_t *, const char *, turso_statement_t **, const char **);
CHECK_FUNCTION(turso_connection_prepare_first, turso_status_code_t, const turso_connection_t *, const char *, turso_statement_t **, size_t *, const char **);
CHECK_FUNCTION(turso_connection_close, turso_status_code_t, const turso_connection_t *, const char **);
CHECK_FUNCTION(turso_statement_execute, turso_status_code_t, const turso_statement_t *, uint64_t *, const char **);
CHECK_FUNCTION(turso_statement_step, turso_status_code_t, const turso_statement_t *, const char **);
CHECK_FUNCTION(turso_statement_run_io, turso_status_code_t, const turso_statement_t *, const char **);
CHECK_FUNCTION(turso_statement_reset, turso_status_code_t, const turso_statement_t *, const char **);
CHECK_FUNCTION(turso_statement_finalize, turso_status_code_t, const turso_statement_t *, const char **);
CHECK_FUNCTION(turso_statement_n_change, int64_t, const turso_statement_t *);
CHECK_FUNCTION(turso_statement_column_count, int64_t, const turso_statement_t *);
CHECK_FUNCTION(turso_statement_column_name, const char *, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_column_decltype, const char *, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_column_declared_name, const char *, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_column_array_dimensions, uint32_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_column_base_type, const char *, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_column_kind, turso_column_kind_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_row_value_kind, turso_type_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_row_value_bytes_count, int64_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_row_value_bytes_ptr, const char *, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_row_value_int, int64_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_row_value_double, double, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_named_position, int64_t, const turso_statement_t *, const char *);
CHECK_FUNCTION(turso_statement_parameters_count, int64_t, const turso_statement_t *);
CHECK_FUNCTION(turso_statement_parameter_name, const char *, const turso_statement_t *, int64_t);
CHECK_FUNCTION(turso_statement_bind_positional_null, turso_status_code_t, const turso_statement_t *, size_t);
CHECK_FUNCTION(turso_statement_bind_positional_int, turso_status_code_t, const turso_statement_t *, size_t, int64_t);
CHECK_FUNCTION(turso_statement_bind_positional_double, turso_status_code_t, const turso_statement_t *, size_t, double);
CHECK_FUNCTION(turso_statement_bind_positional_blob, turso_status_code_t, const turso_statement_t *, size_t, const char *, size_t);
CHECK_FUNCTION(turso_statement_bind_positional_text, turso_status_code_t, const turso_statement_t *, size_t, const char *, size_t);
CHECK_FUNCTION(turso_str_deinit, void, const char *);
CHECK_FUNCTION(turso_database_deinit, void, const turso_database_t *);
CHECK_FUNCTION(turso_connection_deinit, void, const turso_connection_t *);
CHECK_FUNCTION(turso_statement_deinit, void, const turso_statement_t *);

PROBE_LAYOUT(slice_ref, turso_slice_ref_t)
PROBE_LAYOUT(extension_text, turso_extension_text_t)
PROBE_LAYOUT(extension_blob, turso_extension_blob_t)
PROBE_LAYOUT(extension_error, turso_extension_error_t)
PROBE_LAYOUT(extension_value_data, turso_extension_value_data_t)
PROBE_LAYOUT(value, turso_value_t)
PROBE_LAYOUT(agg_ctx, turso_agg_ctx_t)
PROBE_LAYOUT(log, turso_log_t)
PROBE_LAYOUT(config, turso_config_t)
PROBE_LAYOUT(database_config, turso_database_config_t)

PROBE_OFFSET(slice_ref, turso_slice_ref_t, ptr)
PROBE_OFFSET(slice_ref, turso_slice_ref_t, len)
PROBE_OFFSET(extension_text, turso_extension_text_t, subtype)
PROBE_OFFSET(extension_text, turso_extension_text_t, text)
PROBE_OFFSET(extension_text, turso_extension_text_t, len)
PROBE_OFFSET(extension_blob, turso_extension_blob_t, data)
PROBE_OFFSET(extension_blob, turso_extension_blob_t, size)
PROBE_OFFSET(extension_error, turso_extension_error_t, code)
PROBE_OFFSET(extension_error, turso_extension_error_t, message)
PROBE_OFFSET(value, turso_value_t, value_type)
PROBE_OFFSET(value, turso_value_t, value)
PROBE_OFFSET(agg_ctx, turso_agg_ctx_t, state)
PROBE_OFFSET(log, turso_log_t, message)
PROBE_OFFSET(log, turso_log_t, target)
PROBE_OFFSET(log, turso_log_t, file)
PROBE_OFFSET(log, turso_log_t, timestamp)
PROBE_OFFSET(log, turso_log_t, line)
PROBE_OFFSET(log, turso_log_t, level)
PROBE_OFFSET(config, turso_config_t, logger)
PROBE_OFFSET(config, turso_config_t, log_level)
PROBE_OFFSET(database_config, turso_database_config_t, async_io)
PROBE_OFFSET(database_config, turso_database_config_t, path)
PROBE_OFFSET(database_config, turso_database_config_t, experimental_features)
PROBE_OFFSET(database_config, turso_database_config_t, vfs)
PROBE_OFFSET(database_config, turso_database_config_t, encryption_cipher)
PROBE_OFFSET(database_config, turso_database_config_t, encryption_hexkey)

/*
 * These assignments force an independent C compiler to validate the callback
 * typedefs used by the managed Zig callback bridge.
 */
static void context_destructor(uintptr_t context) { (void)context; }
static void value_destructor(turso_value_t *value) { (void)value; }
static turso_value_t scalar(
    uintptr_t context,
    int32_t argc,
    const turso_value_t *argv,
    turso_context_destructor_t context_drop,
    turso_value_destructor_t value_drop)
{
    (void)context;
    (void)argc;
    (void)argv;
    (void)context_drop;
    (void)value_drop;
    return (turso_value_t){0};
}
static turso_agg_ctx_t *aggregate_init(uintptr_t context)
{
    (void)context;
    return NULL;
}
static turso_value_t aggregate_step(
    uintptr_t context,
    turso_agg_ctx_t *aggregate_context,
    int32_t argc,
    const turso_value_t *argv)
{
    (void)context;
    (void)aggregate_context;
    (void)argc;
    (void)argv;
    return (turso_value_t){0};
}
static turso_value_t aggregate_final(uintptr_t context, turso_agg_ctx_t *aggregate_context)
{
    (void)context;
    (void)aggregate_context;
    return (turso_value_t){0};
}
static int32_t collation(
    uintptr_t context,
    const uint8_t *left_ptr,
    size_t left_len,
    const uint8_t *right_ptr,
    size_t right_len)
{
    (void)context;
    (void)left_ptr;
    (void)left_len;
    (void)right_ptr;
    (void)right_len;
    return 0;
}

static turso_context_destructor_t checked_context_destructor = context_destructor;
static turso_value_destructor_t checked_value_destructor = value_destructor;
static turso_scalar_function_t checked_scalar = scalar;
static turso_aggregate_init_function_t checked_aggregate_init = aggregate_init;
static turso_aggregate_step_function_t checked_aggregate_step = aggregate_step;
static turso_aggregate_final_function_t checked_aggregate_final = aggregate_final;
static turso_collation_function_t checked_collation = collation;

int turso_zig_probe_callback_signatures(void)
{
    return checked_context_destructor != NULL &&
           checked_value_destructor != NULL &&
           checked_scalar != NULL &&
           checked_aggregate_init != NULL &&
           checked_aggregate_step != NULL &&
           checked_aggregate_final != NULL &&
           checked_collation != NULL;
}
