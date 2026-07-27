#include "turso_sync.h"

#include <stddef.h>

#define PROBE_LAYOUT(name, type)              \
    size_t turso_zig_sync_probe_size_##name(void) \
    {                                          \
        return sizeof(type);                   \
    }                                          \
    size_t turso_zig_sync_probe_align_##name(void) \
    {                                          \
        return _Alignof(type);                 \
    }

#define PROBE_OFFSET(name, type, field)                   \
    size_t turso_zig_sync_probe_offset_##name##_##field(void) \
    {                                                      \
        return offsetof(type, field);                      \
    }

#define CHECK_FUNCTION(name, return_type, ...)                          \
    typedef return_type (*name##_expected_t)(__VA_ARGS__);              \
    _Static_assert(_Generic(&(name), name##_expected_t: 1, default: 0), \
                   "C function signature changed: " #name)

CHECK_FUNCTION(turso_sync_database_new, turso_status_code_t, const turso_database_config_t *, const turso_sync_database_config_t *, const turso_sync_database_t **, const char **);
CHECK_FUNCTION(turso_sync_database_open, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_create, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_connect, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_stats, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_checkpoint, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_push_changes, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_wait_changes, turso_status_code_t, const turso_sync_database_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_database_apply_changes, turso_status_code_t, const turso_sync_database_t *, const turso_sync_changes_t *, const turso_sync_operation_t **, const char **);
CHECK_FUNCTION(turso_sync_operation_resume, turso_status_code_t, const turso_sync_operation_t *, const char **);
CHECK_FUNCTION(turso_sync_operation_result_kind, turso_sync_operation_result_type_t, const turso_sync_operation_t *);
CHECK_FUNCTION(turso_sync_operation_result_extract_connection, turso_status_code_t, const turso_sync_operation_t *, const turso_connection_t **);
CHECK_FUNCTION(turso_sync_operation_result_extract_changes, turso_status_code_t, const turso_sync_operation_t *, const turso_sync_changes_t **);
CHECK_FUNCTION(turso_sync_operation_result_extract_stats, turso_status_code_t, const turso_sync_operation_t *, turso_sync_stats_t *);
CHECK_FUNCTION(turso_sync_database_io_take_item, turso_status_code_t, const turso_sync_database_t *, const turso_sync_io_item_t **, const char **);
CHECK_FUNCTION(turso_sync_database_io_step_callbacks, turso_status_code_t, const turso_sync_database_t *, const char **);
CHECK_FUNCTION(turso_sync_database_io_request_kind, turso_sync_io_request_type_t, const turso_sync_io_item_t *);
CHECK_FUNCTION(turso_sync_database_io_request_http, turso_status_code_t, const turso_sync_io_item_t *, turso_sync_io_http_request_t *);
CHECK_FUNCTION(turso_sync_database_io_request_http_header, turso_status_code_t, const turso_sync_io_item_t *, size_t, turso_sync_io_http_header_t *);
CHECK_FUNCTION(turso_sync_database_io_request_full_read, turso_status_code_t, const turso_sync_io_item_t *, turso_sync_io_full_read_request_t *);
CHECK_FUNCTION(turso_sync_database_io_request_full_write, turso_status_code_t, const turso_sync_io_item_t *, turso_sync_io_full_write_request_t *);
CHECK_FUNCTION(turso_sync_database_io_poison, turso_status_code_t, const turso_sync_io_item_t *, turso_slice_ref_t *);
CHECK_FUNCTION(turso_sync_database_io_status, turso_status_code_t, const turso_sync_io_item_t *, int32_t);
CHECK_FUNCTION(turso_sync_database_io_push_buffer, turso_status_code_t, const turso_sync_io_item_t *, turso_slice_ref_t *);
CHECK_FUNCTION(turso_sync_database_io_done, turso_status_code_t, const turso_sync_io_item_t *);
CHECK_FUNCTION(turso_sync_database_deinit, void, const turso_sync_database_t *);
CHECK_FUNCTION(turso_sync_operation_deinit, void, const turso_sync_operation_t *);
CHECK_FUNCTION(turso_sync_database_io_item_deinit, void, const turso_sync_io_item_t *);
CHECK_FUNCTION(turso_sync_changes_deinit, void, const turso_sync_changes_t *);

PROBE_LAYOUT(io_http_request, turso_sync_io_http_request_t)
PROBE_LAYOUT(io_http_header, turso_sync_io_http_header_t)
PROBE_LAYOUT(io_full_read_request, turso_sync_io_full_read_request_t)
PROBE_LAYOUT(io_full_write_request, turso_sync_io_full_write_request_t)
PROBE_LAYOUT(stats, turso_sync_stats_t)
PROBE_LAYOUT(database_config, turso_sync_database_config_t)

PROBE_OFFSET(io_http_request, turso_sync_io_http_request_t, url)
PROBE_OFFSET(io_http_request, turso_sync_io_http_request_t, method)
PROBE_OFFSET(io_http_request, turso_sync_io_http_request_t, path)
PROBE_OFFSET(io_http_request, turso_sync_io_http_request_t, body)
PROBE_OFFSET(io_http_request, turso_sync_io_http_request_t, headers)
PROBE_OFFSET(io_http_header, turso_sync_io_http_header_t, key)
PROBE_OFFSET(io_http_header, turso_sync_io_http_header_t, value)
PROBE_OFFSET(io_full_read_request, turso_sync_io_full_read_request_t, path)
PROBE_OFFSET(io_full_write_request, turso_sync_io_full_write_request_t, path)
PROBE_OFFSET(io_full_write_request, turso_sync_io_full_write_request_t, content)
PROBE_OFFSET(stats, turso_sync_stats_t, cdc_operations)
PROBE_OFFSET(stats, turso_sync_stats_t, main_wal_size)
PROBE_OFFSET(stats, turso_sync_stats_t, revert_wal_size)
PROBE_OFFSET(stats, turso_sync_stats_t, last_pull_unix_time)
PROBE_OFFSET(stats, turso_sync_stats_t, last_push_unix_time)
PROBE_OFFSET(stats, turso_sync_stats_t, network_sent_bytes)
PROBE_OFFSET(stats, turso_sync_stats_t, network_received_bytes)
PROBE_OFFSET(stats, turso_sync_stats_t, revision)
PROBE_OFFSET(database_config, turso_sync_database_config_t, path)
PROBE_OFFSET(database_config, turso_sync_database_config_t, remote_url)
PROBE_OFFSET(database_config, turso_sync_database_config_t, client_name)
PROBE_OFFSET(database_config, turso_sync_database_config_t, long_poll_timeout_ms)
PROBE_OFFSET(database_config, turso_sync_database_config_t, bootstrap_if_empty)
PROBE_OFFSET(database_config, turso_sync_database_config_t, reserved_bytes)
PROBE_OFFSET(database_config, turso_sync_database_config_t, partial_bootstrap_strategy_prefix)
PROBE_OFFSET(database_config, turso_sync_database_config_t, partial_bootstrap_strategy_query)
PROBE_OFFSET(database_config, turso_sync_database_config_t, partial_bootstrap_segment_size)
PROBE_OFFSET(database_config, turso_sync_database_config_t, partial_bootstrap_prefetch)
PROBE_OFFSET(database_config, turso_sync_database_config_t, remote_encryption_key)
PROBE_OFFSET(database_config, turso_sync_database_config_t, remote_encryption_cipher)
PROBE_OFFSET(database_config, turso_sync_database_config_t, push_operations_threshold)
PROBE_OFFSET(database_config, turso_sync_database_config_t, pull_bytes_threshold)
PROBE_OFFSET(database_config, turso_sync_database_config_t, logical_mvcc_pull)

int turso_zig_sync_probe_function_signatures(void)
{
    return 1;
}
