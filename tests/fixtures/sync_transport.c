#include "turso_sync.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct turso_sync_database {
    uint32_t round;
    uint32_t next_item;
    uint32_t poisoned;
};

struct turso_sync_operation {
    struct turso_sync_database *database;
    turso_sync_operation_result_type_t kind;
};

struct turso_sync_io_item {
    struct turso_sync_database *database;
    turso_sync_io_request_type_t kind;
    uint32_t round;
    uint32_t index;
    uint32_t terminal;
};

struct fixture_stats {
    uint32_t databases_created;
    uint32_t databases_deinited;
    uint32_t operations_created;
    uint32_t operations_deinited;
    uint32_t items_created;
    uint32_t items_deinited;
    uint32_t callbacks_stepped;
    uint32_t status_calls;
    uint32_t buffer_calls;
    uint32_t done_calls;
    uint32_t poison_calls;
    int32_t statuses[2];
    uint32_t response_bytes;
};

static struct fixture_stats stats;
static char http_url[512] = "https://example.invalid";
static char existing_path[1024] = "existing.meta";
static char missing_path[1024] = "missing.meta";
static char write_path[1024] = "write.meta";
static char poison_message[128] = "sync transport request failure";
static char revision[] = "transport-revision";

static void copy_setting(char *destination, size_t capacity, const char *source)
{
    size_t length = source == NULL ? 0 : strlen(source);
    if (length >= capacity) {
        length = capacity - 1;
    }
    if (length != 0) {
        memcpy(destination, source, length);
    }
    destination[length] = '\0';
}

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
    return "0.8.0-pre.2";
}

void sync_transport_fixture_reset(void)
{
    memset(&stats, 0, sizeof(stats));
    stats.statuses[0] = -1;
    stats.statuses[1] = -1;
    copy_setting(http_url, sizeof(http_url), "https://example.invalid");
    copy_setting(existing_path, sizeof(existing_path), "existing.meta");
    copy_setting(missing_path, sizeof(missing_path), "missing.meta");
    copy_setting(write_path, sizeof(write_path), "write.meta");
    copy_setting(poison_message, sizeof(poison_message), "sync transport request failure");
}

void sync_transport_fixture_paths(
    const char *url,
    const char *existing,
    const char *missing,
    const char *write)
{
    copy_setting(http_url, sizeof(http_url), url);
    copy_setting(existing_path, sizeof(existing_path), existing);
    copy_setting(missing_path, sizeof(missing_path), missing);
    copy_setting(write_path, sizeof(write_path), write);
}

struct fixture_stats sync_transport_fixture_stats(void)
{
    return stats;
}

const char *sync_transport_fixture_poison(void)
{
    return poison_message;
}

turso_status_code_t turso_sync_database_new(
    const turso_database_config_t *db_config,
    const turso_sync_database_config_t *sync_config,
    const turso_sync_database_t **database,
    const char **error_out)
{
    (void)error_out;
    if (db_config == NULL || sync_config == NULL || database == NULL) {
        return TURSO_MISUSE;
    }
    struct turso_sync_database *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    *database = result;
    stats.databases_created += 1;
    return TURSO_OK;
}

static turso_status_code_t new_operation(
    const turso_sync_database_t *database_const,
    turso_sync_operation_result_type_t kind,
    const turso_sync_operation_t **operation)
{
    struct turso_sync_operation *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->database = (struct turso_sync_database *)database_const;
    result->kind = kind;
    *operation = result;
    stats.operations_created += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_create(
    const turso_sync_database_t *database,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)error_out;
    return new_operation(database, TURSO_ASYNC_RESULT_NONE, operation);
}

turso_status_code_t turso_sync_database_stats(
    const turso_sync_database_t *database,
    const turso_sync_operation_t **operation,
    const char **error_out)
{
    (void)error_out;
    return new_operation(database, TURSO_ASYNC_RESULT_STATS, operation);
}

turso_status_code_t turso_sync_operation_resume(
    const turso_sync_operation_t *operation_const,
    const char **error_out)
{
    const struct turso_sync_operation *operation =
        (const struct turso_sync_operation *)operation_const;
    if (operation->database->poisoned != 0) {
        if (error_out != NULL) {
            *error_out = owned_message(poison_message);
        }
        return TURSO_IOERR;
    }
    return operation->database->round < 2 ? TURSO_IO : TURSO_DONE;
}

turso_sync_operation_result_type_t turso_sync_operation_result_kind(
    const turso_sync_operation_t *operation)
{
    return ((const struct turso_sync_operation *)operation)->kind;
}

turso_status_code_t turso_sync_operation_result_extract_stats(
    const turso_sync_operation_t *operation,
    turso_sync_stats_t *result)
{
    (void)operation;
    memset(result, 0, sizeof(*result));
    result->cdc_operations = 17;
    result->network_received_bytes = 29;
    result->revision.ptr = revision;
    result->revision.len = strlen(revision);
    return TURSO_OK;
}

static uint32_t item_count(uint32_t round)
{
    return round == 0 ? 3 : 2;
}

static turso_sync_io_request_type_t item_kind(uint32_t round, uint32_t index)
{
    if (round == 0) {
        static const turso_sync_io_request_type_t first[] = {
            TURSO_SYNC_IO_HTTP,
            TURSO_SYNC_IO_FULL_READ,
            TURSO_SYNC_IO_FULL_WRITE,
        };
        return first[index];
    }
    static const turso_sync_io_request_type_t second[] = {
        TURSO_SYNC_IO_HTTP,
        TURSO_SYNC_IO_FULL_READ,
    };
    return second[index];
}

turso_status_code_t turso_sync_database_io_take_item(
    const turso_sync_database_t *database_const,
    const turso_sync_io_item_t **item,
    const char **error_out)
{
    (void)error_out;
    struct turso_sync_database *database =
        (struct turso_sync_database *)database_const;
    if (database->round >= 2 ||
        database->next_item >= item_count(database->round)) {
        *item = NULL;
        return TURSO_OK;
    }

    struct turso_sync_io_item *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return TURSO_ERROR;
    }
    result->database = database;
    result->round = database->round;
    result->index = database->next_item;
    result->kind = item_kind(database->round, database->next_item);
    database->next_item += 1;
    *item = result;
    stats.items_created += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_step_callbacks(
    const turso_sync_database_t *database_const,
    const char **error_out)
{
    (void)error_out;
    struct turso_sync_database *database =
        (struct turso_sync_database *)database_const;
    database->round += 1;
    database->next_item = 0;
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
    const turso_sync_io_item_t *item_const,
    turso_sync_io_http_request_t *request)
{
    const struct turso_sync_io_item *item =
        (const struct turso_sync_io_item *)item_const;
    request->url = slice(http_url, strlen(http_url));
    if (item->round == 0) {
        request->method = slice("POST", 4);
        request->path = slice("/sync?round=one", 15);
        request->body = slice("request-body", 12);
    } else {
        request->method = slice("GET", 3);
        request->path = slice("/missing", 8);
        request->body = slice(NULL, 0);
    }
    request->headers = 4;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_request_http_header(
    const turso_sync_io_item_t *item,
    size_t index,
    turso_sync_io_http_header_t *header)
{
    (void)item;
    if (index == 0) {
        header->key = slice("x-native", 8);
        header->value = slice("native-value", 12);
        return TURSO_OK;
    }
    if (index == 1) {
        header->key = slice("content-type", 12);
        header->value = slice("application/octet-stream", 24);
        return TURSO_OK;
    }
    if (index == 2) {
        header->key = slice("Authorization", 13);
        header->value = slice("Bearer stale-upper", 18);
        return TURSO_OK;
    }
    if (index == 3) {
        header->key = slice("aUtHoRiZaTiOn", 13);
        header->value = slice("Bearer stale-mixed", 18);
        return TURSO_OK;
    }
    return TURSO_MISUSE;
}

turso_status_code_t turso_sync_database_io_request_full_read(
    const turso_sync_io_item_t *item_const,
    turso_sync_io_full_read_request_t *request)
{
    const struct turso_sync_io_item *item =
        (const struct turso_sync_io_item *)item_const;
    const char *path = item->round == 0 ? existing_path : missing_path;
    request->path = slice(path, strlen(path));
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_request_full_write(
    const turso_sync_io_item_t *item,
    turso_sync_io_full_write_request_t *request)
{
    (void)item;
    request->path = slice(write_path, strlen(write_path));
    request->content = slice("atomic-replacement", 18);
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_poison(
    const turso_sync_io_item_t *item_const,
    turso_slice_ref_t *error)
{
    struct turso_sync_io_item *item =
        (struct turso_sync_io_item *)item_const;
    if (item->terminal != 0 || error == NULL || error->ptr == NULL) {
        return TURSO_MISUSE;
    }
    size_t length = error->len < sizeof(poison_message) - 1
        ? error->len
        : sizeof(poison_message) - 1;
    memcpy(poison_message, error->ptr, length);
    poison_message[length] = '\0';
    item->database->poisoned = 1;
    item->terminal = 1;
    stats.poison_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_status(
    const turso_sync_io_item_t *item_const,
    int32_t status)
{
    const struct turso_sync_io_item *item =
        (const struct turso_sync_io_item *)item_const;
    if (status < 0 || status > 65535 || item->round > 1) {
        return TURSO_MISUSE;
    }
    stats.statuses[item->round] = status;
    stats.status_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_push_buffer(
    const turso_sync_io_item_t *item,
    turso_slice_ref_t *buffer)
{
    (void)item;
    if (buffer == NULL || buffer->ptr == NULL) {
        return TURSO_MISUSE;
    }
    stats.buffer_calls += 1;
    stats.response_bytes += (uint32_t)buffer->len;
    return TURSO_OK;
}

turso_status_code_t turso_sync_database_io_done(
    const turso_sync_io_item_t *item_const)
{
    struct turso_sync_io_item *item =
        (struct turso_sync_io_item *)item_const;
    if (item->terminal != 0) {
        return TURSO_MISUSE;
    }
    item->terminal = 1;
    stats.done_calls += 1;
    return TURSO_OK;
}

void turso_sync_database_io_item_deinit(const turso_sync_io_item_t *item)
{
    if (item != NULL) {
        stats.items_deinited += 1;
        free((void *)item);
    }
}

void turso_sync_operation_deinit(const turso_sync_operation_t *operation)
{
    if (operation != NULL) {
        stats.operations_deinited += 1;
        free((void *)operation);
    }
}

void turso_sync_database_deinit(const turso_sync_database_t *database)
{
    if (database != NULL) {
        stats.databases_deinited += 1;
        free((void *)database);
    }
}

void turso_str_deinit(const char *message)
{
    free((void *)message);
}
