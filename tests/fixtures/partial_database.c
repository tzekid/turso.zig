#include "turso.h"

#include <stdlib.h>
#include <string.h>

static int mode;
static size_t created;
static size_t deinited;
static size_t error_deinited;
static int fake_database;

static const char *owned_message(const char *message)
{
    const size_t size = strlen(message) + 1;
    char *result = malloc(size);
    if (result != NULL) {
        memcpy(result, message, size);
    }
    return result;
}

const char *turso_version(void)
{
    return "0.8.0-pre.7";
}

void turso_zig_database_set_mode(int value)
{
    mode = value;
}

void turso_zig_database_reset_counts(void)
{
    created = 0;
    deinited = 0;
    error_deinited = 0;
}

size_t turso_zig_database_created(void)
{
    return created;
}

size_t turso_zig_database_deinited(void)
{
    return deinited;
}

size_t turso_zig_database_error_deinited(void)
{
    return error_deinited;
}

turso_status_code_t turso_database_new(
    const turso_database_config_t *config,
    const turso_database_t **database,
    const char **error_opt_out)
{
    (void)config;
    created += 1;
    *database = (const turso_database_t *)&fake_database;
    if (mode == 1) {
        *error_opt_out = owned_message("database new failed");
        return TURSO_ERROR;
    }
    *error_opt_out = NULL;
    return TURSO_OK;
}

turso_status_code_t turso_database_open(
    const turso_database_t *database,
    const char **error_opt_out)
{
    (void)database;
    if (mode == 2) {
        *error_opt_out = owned_message("database open failed");
        return TURSO_ERROR;
    }
    *error_opt_out = NULL;
    return TURSO_OK;
}

void turso_database_deinit(const turso_database_t *database)
{
    if (database != NULL) {
        deinited += 1;
    }
}

void turso_str_deinit(const char *message)
{
    if (message != NULL) {
        error_deinited += 1;
        free((void *)message);
    }
}
