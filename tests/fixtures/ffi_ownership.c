#include "turso.h"

#include <stdlib.h>
#include <string.h>

static size_t allocations;
static size_t deinits;

void turso_zig_error_reset(void)
{
    allocations = 0;
    deinits = 0;
}

const char *turso_zig_error_new(void)
{
    static const char message[] = "owned native error";
    char *result = malloc(sizeof(message));
    if (result == NULL) {
        return NULL;
    }
    memcpy(result, message, sizeof(message));
    allocations += 1;
    return result;
}

size_t turso_zig_error_allocations(void)
{
    return allocations;
}

size_t turso_zig_error_deinits(void)
{
    return deinits;
}

void turso_str_deinit(const char *message)
{
    if (message == NULL) {
        return;
    }
    deinits += 1;
    free((void *)message);
}
