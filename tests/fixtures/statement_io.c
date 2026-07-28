#include "turso.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct turso_connection {
    uint32_t live;
};

enum pending_operation {
    PENDING_NONE = 0,
    PENDING_EXECUTE,
    PENDING_STEP,
    PENDING_FINALIZE,
};

struct turso_statement {
    uint32_t execute_io_turns;
    uint32_t step_io_turns;
    uint32_t finalize_io_turns;
    uint32_t fail_run_io_call;
    uint32_t run_io_calls;
    enum pending_operation pending;
    bool row_emitted;
};

struct fixture_stats {
    uint32_t prepare_calls;
    uint32_t execute_calls;
    uint32_t step_calls;
    uint32_t run_io_calls;
    uint32_t reset_calls;
    uint32_t finalize_calls;
    uint32_t statement_deinit_calls;
    uint32_t connection_deinit_calls;
    uint32_t string_deinit_calls;
};

static struct turso_connection fixture_connection;
static struct fixture_stats stats;
static uint32_t configured_execute_io_turns;
static uint32_t configured_step_io_turns;
static uint32_t configured_finalize_io_turns;
static uint32_t configured_fail_run_io_call;
static uint32_t configured_fail_reset_call;

void statement_io_fixture_reset(
    uint32_t execute_io_turns,
    uint32_t step_io_turns,
    uint32_t finalize_io_turns,
    uint32_t fail_run_io_call)
{
    memset(&stats, 0, sizeof(stats));
    fixture_connection.live = 1;
    configured_execute_io_turns = execute_io_turns;
    configured_step_io_turns = step_io_turns;
    configured_finalize_io_turns = finalize_io_turns;
    configured_fail_run_io_call = fail_run_io_call;
    configured_fail_reset_call = 0;
}

void statement_io_fixture_fail_reset_call(uint32_t call)
{
    configured_fail_reset_call = call;
}

void *statement_io_fixture_connection(void)
{
    return &fixture_connection;
}

struct fixture_stats statement_io_fixture_stats(void)
{
    return stats;
}

turso_status_code_t turso_connection_prepare_single(
    const turso_connection_t *connection,
    const char *sql,
    turso_statement_t **statement_out,
    const char **error_out)
{
    (void)sql;
    (void)error_out;
    if (connection == NULL || statement_out == NULL || fixture_connection.live == 0) {
        return TURSO_MISUSE;
    }

    struct turso_statement *statement = calloc(1, sizeof(*statement));
    if (statement == NULL) {
        return TURSO_ERROR;
    }
    statement->execute_io_turns = configured_execute_io_turns;
    statement->step_io_turns = configured_step_io_turns;
    statement->finalize_io_turns = configured_finalize_io_turns;
    statement->fail_run_io_call = configured_fail_run_io_call;
    *statement_out = statement;
    stats.prepare_calls += 1;
    return TURSO_OK;
}

turso_status_code_t turso_statement_execute(
    const turso_statement_t *statement_const,
    uint64_t *rows_changed,
    const char **error_out)
{
    (void)error_out;
    struct turso_statement *statement = (struct turso_statement *)statement_const;
    stats.execute_calls += 1;
    if (statement->execute_io_turns != 0) {
        statement->pending = PENDING_EXECUTE;
        return TURSO_IO;
    }
    statement->pending = PENDING_NONE;
    if (rows_changed != NULL) {
        *rows_changed = 7;
    }
    return TURSO_DONE;
}

turso_status_code_t turso_statement_step(
    const turso_statement_t *statement_const,
    const char **error_out)
{
    (void)error_out;
    struct turso_statement *statement = (struct turso_statement *)statement_const;
    stats.step_calls += 1;
    if (statement->step_io_turns != 0) {
        statement->pending = PENDING_STEP;
        return TURSO_IO;
    }
    statement->pending = PENDING_NONE;
    if (!statement->row_emitted) {
        statement->row_emitted = true;
        return TURSO_ROW;
    }
    return TURSO_DONE;
}

turso_status_code_t turso_statement_run_io(
    const turso_statement_t *statement_const,
    const char **error_out)
{
    struct turso_statement *statement = (struct turso_statement *)statement_const;
    stats.run_io_calls += 1;
    statement->run_io_calls += 1;
    if (statement->fail_run_io_call != 0 &&
        statement->run_io_calls == statement->fail_run_io_call) {
        if (error_out != NULL) {
            const char message[] = "fixture run_io failure";
            char *copy = malloc(sizeof(message));
            if (copy != NULL) {
                memcpy(copy, message, sizeof(message));
                *error_out = copy;
            }
        }
        return TURSO_IOERR;
    }

    switch (statement->pending) {
    case PENDING_EXECUTE:
        statement->execute_io_turns -= 1;
        break;
    case PENDING_STEP:
        statement->step_io_turns -= 1;
        break;
    case PENDING_FINALIZE:
        statement->finalize_io_turns -= 1;
        break;
    case PENDING_NONE:
        return TURSO_MISUSE;
    }
    statement->pending = PENDING_NONE;
    return TURSO_OK;
}

turso_status_code_t turso_statement_reset(
    const turso_statement_t *statement_const,
    const char **error_out)
{
    struct turso_statement *statement = (struct turso_statement *)statement_const;
    stats.reset_calls += 1;
    if (configured_fail_reset_call != 0 &&
        stats.reset_calls == configured_fail_reset_call) {
        if (error_out != NULL) {
            const char message[] = "fixture reset failure";
            char *copy = malloc(sizeof(message));
            if (copy != NULL) {
                memcpy(copy, message, sizeof(message));
                *error_out = copy;
            }
        }
        return TURSO_IOERR;
    }
    statement->execute_io_turns = 0;
    statement->step_io_turns = 0;
    statement->pending = PENDING_NONE;
    statement->row_emitted = false;
    return TURSO_OK;
}

turso_status_code_t turso_statement_finalize(
    const turso_statement_t *statement_const,
    const char **error_out)
{
    (void)error_out;
    struct turso_statement *statement = (struct turso_statement *)statement_const;
    stats.finalize_calls += 1;
    if (statement->finalize_io_turns != 0) {
        statement->pending = PENDING_FINALIZE;
        return TURSO_IO;
    }
    statement->pending = PENDING_NONE;
    return TURSO_DONE;
}

int64_t turso_statement_column_count(const turso_statement_t *statement)
{
    (void)statement;
    return 1;
}

int64_t turso_statement_parameters_count(const turso_statement_t *statement)
{
    (void)statement;
    return 0;
}

turso_status_code_t turso_statement_bind_positional_null(
    const turso_statement_t *statement,
    size_t position)
{
    (void)statement;
    (void)position;
    return TURSO_OK;
}

turso_status_code_t turso_statement_bind_positional_int(
    const turso_statement_t *statement,
    size_t position,
    int64_t value)
{
    (void)statement;
    (void)position;
    (void)value;
    return TURSO_OK;
}

turso_status_code_t turso_statement_bind_positional_double(
    const turso_statement_t *statement,
    size_t position,
    double value)
{
    (void)statement;
    (void)position;
    (void)value;
    return TURSO_OK;
}

turso_status_code_t turso_statement_bind_positional_text(
    const turso_statement_t *statement,
    size_t position,
    const char *ptr,
    size_t len)
{
    (void)statement;
    (void)position;
    (void)ptr;
    (void)len;
    return TURSO_OK;
}

turso_status_code_t turso_statement_bind_positional_blob(
    const turso_statement_t *statement,
    size_t position,
    const char *ptr,
    size_t len)
{
    (void)statement;
    (void)position;
    (void)ptr;
    (void)len;
    return TURSO_OK;
}

bool turso_connection_get_autocommit(const turso_connection_t *connection)
{
    (void)connection;
    return true;
}

void turso_str_deinit(const char *string)
{
    stats.string_deinit_calls += 1;
    free((void *)string);
}

void turso_statement_deinit(const turso_statement_t *statement)
{
    stats.statement_deinit_calls += 1;
    free((void *)statement);
}

void turso_connection_deinit(const turso_connection_t *connection)
{
    (void)connection;
    stats.connection_deinit_calls += 1;
    fixture_connection.live = 0;
}
