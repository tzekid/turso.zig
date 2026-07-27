#include "turso.h"

int turso_zig_mismatch_database_new_calls = 0;

const char *turso_version(void)
{
    return "0.0.0-incompatible";
}

turso_status_code_t turso_database_new(
    const turso_database_config_t *config,
    const turso_database_t **database,
    const char **error_opt_out)
{
    (void)config;
    (void)database;
    (void)error_opt_out;
    turso_zig_mismatch_database_new_calls += 1;
    return TURSO_ERROR;
}

turso_status_code_t turso_database_open(
    const turso_database_t *database,
    const char **error_opt_out)
{
    (void)database;
    (void)error_opt_out;
    return TURSO_ERROR;
}

void turso_database_deinit(const turso_database_t *database)
{
    (void)database;
}

void turso_str_deinit(const char *message)
{
    (void)message;
}
