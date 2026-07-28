#include "turso_sync.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct turso_sync_database {
    uint32_t live;
};

struct turso_sync_operation {
    turso_sync_operation_result_type_t kind;
    uint32_t polls;
};

struct turso_sync_io_item {
    turso_sync_io_request_type_t kind;
    uint32_t terminal;
};

struct turso_sync_changes {
    uint32_t live;
};

struct turso_connection {
    uint32_t live;
};

struct fixture_stats {
    uint32_t databases_created;
    uint32_t databases_deinited;
    uint32_t operations_created;
    uint32_t operations_deinited;
    uint32_t items_created;
    uint32_t items_deinited;
    uint32_t changes_created;
    uint32_t changes_deinited;
    uint32_t changes_consumed;
    uint32_t connections_created;
    uint32_t connections_deinited;
    uint32_t strings_deinited;
    uint32_t callbacks_stepped;
    uint32_t status_calls;
    uint32_t buffer_calls;
    uint32_t done_calls;
    uint32_t poison_calls;
};

static struct fixture_stats stats;
static int constructor_mode;
static int operation_constructor_failure;
static int resume_failure;
static int result_mismatch;
static int null_changes;
static int apply_failure;
static int emit_io;
static int io_taken;
static int invalid_header_count;
static turso_sync_io_request_type_t io_kind = TURSO_SYNC_IO_HTTP;
static char revision[] = "rev-123";

static const char *owned_message(const char *message)
{
    size_t size = strlen(message) + 1;
    char *result = malloc(size);
    if (result != NULL) {
        memcpy(result, message, size);
    }
    return result;
}

const char *turso_version(void)
{
    return "0.7.1";
}

void sync_lifecycle_fixture_reset(void)
{
    memset(&stats, 0, sizeof(stats));
    constructor_mode = 0;
    operation_constructor_failure = 0;
    resume_failure = 0;
    result_mismatch = 0;
    null_changes = 0;
    apply_failure = 0;
    emit_io = 0;
    io_taken = 0;
    invalid_header_count = 0;
    io_kind = TURSO_SYNC_IO_HTTP;
    memcpy(revision, "rev-123", sizeof(revision));
}

void sync_lifecycle_fixture_set(
    int constructor,
    int operation_failure,
    int poll_failure,
    int mismatch,
    int no_changes,
    int fail_apply,
    int needs_io,
    int request_kind,
    int bad_headers)
{
    constructor_mode = constructor;
    operation_constructor_failure = operation_failure;
    resume_failure = poll_failure;
    result_mismatch = mismatch;
    null_changes = no_changes;
    apply_failure = fail_apply;
    emit_io = needs_io;
    io_kind = (turso_sync_io_request_type_t)request_kind;
    invalid_header_count = bad_headers;
}

struct fixture_stats sync_lifecycle_fixture_stats(void)
{
    return stats;
}

turso_status_code_t turso_sync_database_new(
    const turso_database_config_t *db_config,
    const turso_sync_database_config_t *sync_config,
    const turso_sync_database_t **database,
    const char **error_out)
{
    if (db_config == NULL || sync_config == NULL || database == NULL) {
        return TURSO_MISUSE;
    }
    if (strcmp(db_config->path, sync_config->path) != 0) {
        return TURSO_MISUSE;
    }
    struct turso_sync_database *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->live = 1;
    *database = result;
    stats.databases_created += 1;
    if (constructor_mode != 0) {
        if (error_out != NULL) {
            *error_out = owned_message("constructor secret-redacted failure");
        }
        return TURSO_ERROR;
    }
    return TURSO_OK;
}

static turso_status_code_t new_operation(
    turso_sync_operation_result_type_t kind,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    struct turso_sync_operation *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->kind = result_mismatch ? TURSO_ASYNC_RESULT_STATS : kind;
    *operation = result;
    stats.operations_created += 1;
    if (operation_constructor_failure != 0) {
        if (error_out != NULL) {
            *error_out = owned_message("operation constructor failure");
        }
        return TURSO_ERROR;
    }
    return TURSO_OK;
}

#define VOID_OPERATION(name) \
    turso_status_code_t name( \
        const turso_sync_database_t *database, \
        const turso_sync_operation_t **operation, \
        const char **error_out) \
    { \
        (void)database; \
        return new_operation(TURSO_ASYNC_RESULT_NONE, operation, error_out); \
    }

VOID_OPERATION(turso_sync_database_open)
VOID_OPERATION(turso_sync_database_create)
VOID_OPERATION(turso_sync_database_checkpoint)
VOID_OPERATION(turso_sync_database_push_changes)

turso_status_code_t turso_sync_database_connect(
    const turso_sync_database_t *database,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)database;
    return new_operation(TURSO_ASYNC_RESULT_CONNECTION, operation, error_out);
}

turso_status_code_t turso_sync_database_stats(
    const turso_sync_database_t *database,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)database;
    return new_operation(TURSO_ASYNC_RESULT_STATS, operation, error_out);
}

turso_status_code_t turso_sync_database_wait_changes(
    const turso_sync_database_t *database,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)database;
    return new_operation(TURSO_ASYNC_RESULT_CHANGES, operation, error_out);
}

turso_status_code_t turso_sync_database_apply_changes(
    const turso_sync_database_t *database,
    const turso_sync_changes_t *changes,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)database;
    if (changes != NULL) {
        stats.changes_consumed += 1;
        free((void *)changes);
    }
    if (apply_failure != 0) {
        if (error_out != NULL) {
            *error_out = owned_message("apply failure");
        }
        return TURSO_IOERR;
    }
    return new_operation(TURSO_ASYNC_RESULT_NONE, operation, error_out);
}

turso_status_code_t turso_sync_operation_resume(
    const turso_sync_operation_t *operation_const,
    const char **error_out)
{
    struct turso_sync_operation *operation = (struct turso_sync_operation *)operation_const;
    operation->polls += 1;
    if (resume_failure != 0) {
        if (error_out != NULL) {
            *error_out = owned_message("resume failure");
        }
        return TURSO_IOERR;
    }
    if (emit_io != 0 && operation->polls == 1) {
        return TURSO_IO;
    }
    return TURSO_DONE;
}

turso_sync_operation_result_type_t turso_sync_operation_result_kind(
    const turso_sync_operation_t *operation)
{
    return ((const struct turso_sync_operation *)operation)->kind;
}

turso_status_code_t turso_sync_operation_result_extract_connection(
    const turso_sync_operation_t *operation,
    const turso_connection_t **connection)
{
    (void)operation;
    struct turso_connection *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->live = 1;
    *connection = result;
    stats.connections_created += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_operation_result_extract_changes(
    const turso_sync_operation_t *operation,
    const turso_sync_changes_t **changes)
{
    (void)operation;
    if (null_changes != 0) {
        *changes = NULL;
        return TURSO_OK;
    }
    struct turso_sync_changes *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->live = 1;
    *changes = result;
    stats.changes_created += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_operation_result_extract_stats(
    const turso_sync_operation_t *operation,
    turso_sync_stats_t *result)
{
    (void)operation;
    memset(result, 0, sizeof(*result));
    result->cdc_operations = 9;
    result->network_sent_bytes = 11;
    result->revision.ptr = revision;
    result->revision.len = strlen(revision);
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_take_item(
    const turso_sync_database_t *database,
    const turso_sync_io_item_t **item,
    const char **error_out)
{
    (void)database;
    (void)error_out;
    if (emit_io == 0 || io_taken != 0) {
        *item = NULL;
        return TURSO_OK;
    }
    struct turso_sync_io_item *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->kind = io_kind;
    *item = result;
    io_taken = 1;
    stats.items_created += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_step_callbacks(
    const turso_sync_database_t *database,
    const char **error_out)
{
    (void)database;
    (void)error_out;
    stats.callbacks_stepped += 1;
    return TURSO_OK;
}

turso_sync_io_request_type_t turso_sync_database_io_request_kind(
    const turso_sync_io_item_t *item)
{
    return ((const struct turso_sync_io_item *)item)->kind;
}

static turso_slice_ref_t slice(const void *ptr, size_t len)
{
    turso_slice_ref_t result = {ptr, len};
    return result;
}

turso_status_code_t turso_sync_database_io_request_http(
    const turso_sync_io_item_t *item,
    turso_sync_io_http_request_t *request)
{
    (void)item;
    request->url = slice(NULL, 0);
    request->method = slice("POST", 4);
    request->path = slice("/sync", 5);
    request->body = slice(NULL, 0);
    request->headers = invalid_header_count ? -1 : 2;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_request_http_header(
    const turso_sync_io_item_t *item,
    size_t index,
    turso_sync_io_http_header_t *header)
{
    (void)item;
    if (index == 0) {
        header->key = slice("x-one", 5);
        header->value = slice("", 0);
        return TURSO_OK;
    }
    if (index == 1) {
        header->key = slice("x-two", 5);
        header->value = slice("2", 1);
        return TURSO_OK;
    }
    return TURSO_MISUSE;
}

turso_status_code_t turso_sync_database_io_request_full_read(
    const turso_sync_io_item_t *item,
    turso_sync_io_full_read_request_t *request)
{
    (void)item;
    request->path = slice("meta.db", 7);
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_request_full_write(
    const turso_sync_io_item_t *item,
    turso_sync_io_full_write_request_t *request)
{
    (void)item;
    request->path = slice("meta.db", 7);
    request->content = slice(NULL, 0);
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_poison(
    const turso_sync_io_item_t *item_const,
    turso_slice_ref_t *error)
{
    (void)error;
    struct turso_sync_io_item *item = (struct turso_sync_io_item *)item_const;
    if (item->terminal != 0) return TURSO_MISUSE;
    item->terminal = 1;
    stats.poison_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_status(
    const turso_sync_io_item_t *item_const,
    int32_t status)
{
    (void)item_const;
    if (status < 0 || status > 65535) return TURSO_MISUSE;
    stats.status_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_push_buffer(
    const turso_sync_io_item_t *item_const,
    turso_slice_ref_t *buffer)
{
    (void)item_const;
    if (buffer == NULL || buffer->ptr == NULL) return TURSO_MISUSE;
    stats.buffer_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_done(
    const turso_sync_io_item_t *item_const)
{
    struct turso_sync_io_item *item = (struct turso_sync_io_item *)item_const;
    if (item->terminal != 0) return TURSO_MISUSE;
    item->terminal = 1;
    stats.done_calls += 1;
    return TURSO_OK;
}

void turso_sync_database_deinit(const turso_sync_database_t *database)
{
    if (database != NULL) {
        stats.databases_deinited += 1;
        free((void *)database);
    }
}

void turso_sync_operation_deinit(const turso_sync_operation_t *operation)
{
    if (operation != NULL) {
        stats.operations_deinited += 1;
        memset(revision, 'x', sizeof(revision) - 1);
        free((void *)operation);
    }
}

void turso_sync_database_io_item_deinit(const turso_sync_io_item_t *item)
{
    if (item != NULL) {
        stats.items_deinited += 1;
        free((void *)item);
    }
}

void turso_sync_changes_deinit(const turso_sync_changes_t *changes)
{
    if (changes != NULL) {
        stats.changes_deinited += 1;
        free((void *)changes);
    }
}

void turso_connection_deinit(const turso_connection_t *connection)
{
    if (connection != NULL) {
        stats.connections_deinited += 1;
        free((void *)connection);
    }
}

bool turso_connection_get_autocommit(const turso_connection_t *connection)
{
    (void)connection;
    return true;
}

void turso_str_deinit(const char *message)
{
    if (message != NULL) {
        stats.strings_deinited += 1;
        free((void *)message);
    }
}
