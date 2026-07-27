#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

typedef ssize_t (*pwrite_fn)(int, const void *, size_t, off_t);
typedef ssize_t (*pwrite64_fn)(int, const void *, size_t, off64_t);
typedef ssize_t (*pwritev_fn)(int, const struct iovec *, int, off_t);
typedef ssize_t (*pwritev64_fn)(int, const struct iovec *, int, off64_t);

static atomic_uint_fast64_t matched_calls = ATOMIC_VAR_INIT(0);
static atomic_bool short_write_done = ATOMIC_VAR_INIT(false);

static void load_symbol(void *destination, size_t destination_size, const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    if (symbol == NULL || destination_size != sizeof(symbol)) {
        static const char message[] = "disk fault shim could not resolve a libc write symbol\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(125);
    }
    memcpy(destination, &symbol, sizeof(symbol));
}

static bool has_known_sidecar_suffix(const char *suffix) {
    return suffix[0] == '\0' || strcmp(suffix, "-wal") == 0 ||
           strcmp(suffix, "-shm") == 0 || strcmp(suffix, "-lock") == 0;
}

static bool targets_database_fd(int fd) {
    const char *armed = getenv("TURSO_DISK_FAULT_ARMED");
    const char *target = getenv("TURSO_DISK_FAULT_PATH");
    if (armed == NULL || strcmp(armed, "1") != 0 || target == NULL ||
        target[0] != '/') {
        return false;
    }

    char link_path[64];
    const int link_length =
        snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", fd);
    if (link_length < 0 || (size_t)link_length >= sizeof(link_path)) {
        return false;
    }

    char fd_path[4096];
    const ssize_t path_length =
        readlink(link_path, fd_path, sizeof(fd_path) - 1);
    if (path_length < 0 || (size_t)path_length >= sizeof(fd_path)) {
        return false;
    }
    fd_path[path_length] = '\0';

    const size_t target_length = strlen(target);
    return strncmp(fd_path, target, target_length) == 0 &&
           has_known_sidecar_suffix(fd_path + target_length);
}

static uint_fast64_t failure_threshold(void) {
    const char *value = getenv("TURSO_DISK_FAULT_AFTER");
    if (value == NULL || value[0] == '\0') {
        return 0;
    }
    char *end = NULL;
    errno = 0;
    const unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        return 0;
    }
    return (uint_fast64_t)parsed;
}

static void record_event(const char *event) {
    const char *report = getenv("TURSO_DISK_FAULT_REPORT");
    if (report == NULL || report[0] != '/') {
        return;
    }
    const int fd = open(report, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        return;
    }
    (void)write(fd, event, strlen(event));
    (void)close(fd);
}

enum fault_action {
    fault_none,
    fault_enospc,
    fault_short,
    fault_eio,
};

static enum fault_action action_for_call(int fd) {
    if (!targets_database_fd(fd)) {
        return fault_none;
    }

    const uint_fast64_t call_index =
        atomic_fetch_add_explicit(&matched_calls, 1, memory_order_relaxed);
    if (call_index < failure_threshold()) {
        return fault_none;
    }

    const char *mode = getenv("TURSO_DISK_FAULT_MODE");
    if (mode != NULL && strcmp(mode, "enospc") == 0) {
        return fault_enospc;
    }
    if (mode != NULL && strcmp(mode, "short") == 0) {
        bool expected = false;
        if (atomic_compare_exchange_strong_explicit(
                &short_write_done, &expected, true, memory_order_relaxed,
                memory_order_relaxed)) {
            return fault_short;
        }
        return fault_eio;
    }
    return fault_none;
}

static ssize_t fail_with(int error_number, const char *event) {
    record_event(event);
    errno = error_number;
    return -1;
}

static size_t partial_count(size_t count) {
    if (count <= 1) {
        return count;
    }
    const size_t half = count / 2;
    return half == 0 ? 1 : half;
}

ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset) {
    pwrite_fn real_pwrite = NULL;
    load_symbol(&real_pwrite, sizeof(real_pwrite), "pwrite");

    switch (action_for_call(fd)) {
        case fault_enospc:
            return fail_with(ENOSPC, "enospc\n");
        case fault_eio:
            return fail_with(EIO, "io-error\n");
        case fault_short: {
            const size_t requested = partial_count(count);
            const ssize_t result = real_pwrite(fd, buffer, requested, offset);
            if (result > 0 && (size_t)result < count) {
                record_event("short-write\n");
            }
            return result;
        }
        case fault_none:
            return real_pwrite(fd, buffer, count, offset);
    }
    return fail_with(EIO, "invalid-action\n");
}

ssize_t pwrite64(int fd, const void *buffer, size_t count, off64_t offset) {
    pwrite64_fn real_pwrite64 = NULL;
    load_symbol(&real_pwrite64, sizeof(real_pwrite64), "pwrite64");

    switch (action_for_call(fd)) {
        case fault_enospc:
            return fail_with(ENOSPC, "enospc\n");
        case fault_eio:
            return fail_with(EIO, "io-error\n");
        case fault_short: {
            const size_t requested = partial_count(count);
            const ssize_t result =
                real_pwrite64(fd, buffer, requested, offset);
            if (result > 0 && (size_t)result < count) {
                record_event("short-write\n");
            }
            return result;
        }
        case fault_none:
            return real_pwrite64(fd, buffer, count, offset);
    }
    return fail_with(EIO, "invalid-action\n");
}

static ssize_t partial_pwritev(
    pwrite_fn real_pwrite,
    int fd,
    const struct iovec *iov,
    int iov_count,
    off_t offset
) {
    size_t total = 0;
    for (int index = 0; index < iov_count; ++index) {
        total += iov[index].iov_len;
    }
    for (int index = 0; index < iov_count; ++index) {
        if (iov[index].iov_len == 0) {
            continue;
        }
        size_t requested = partial_count(total);
        if (requested > iov[index].iov_len) {
            requested = iov[index].iov_len;
        }
        const ssize_t result =
            real_pwrite(fd, iov[index].iov_base, requested, offset);
        if (result > 0 && (size_t)result < total) {
            record_event("short-write\n");
        }
        return result;
    }
    return real_pwrite(fd, "", 0, offset);
}

ssize_t pwritev(
    int fd,
    const struct iovec *iov,
    int iov_count,
    off_t offset
) {
    pwritev_fn real_pwritev = NULL;
    pwrite_fn real_pwrite = NULL;
    load_symbol(&real_pwritev, sizeof(real_pwritev), "pwritev");

    switch (action_for_call(fd)) {
        case fault_enospc:
            return fail_with(ENOSPC, "enospc\n");
        case fault_eio:
            return fail_with(EIO, "io-error\n");
        case fault_short:
            load_symbol(&real_pwrite, sizeof(real_pwrite), "pwrite");
            return partial_pwritev(
                real_pwrite, fd, iov, iov_count, offset);
        case fault_none:
            return real_pwritev(fd, iov, iov_count, offset);
    }
    return fail_with(EIO, "invalid-action\n");
}

static ssize_t partial_pwritev64(
    pwrite64_fn real_pwrite64,
    int fd,
    const struct iovec *iov,
    int iov_count,
    off64_t offset
) {
    size_t total = 0;
    for (int index = 0; index < iov_count; ++index) {
        total += iov[index].iov_len;
    }
    for (int index = 0; index < iov_count; ++index) {
        if (iov[index].iov_len == 0) {
            continue;
        }
        size_t requested = partial_count(total);
        if (requested > iov[index].iov_len) {
            requested = iov[index].iov_len;
        }
        const ssize_t result =
            real_pwrite64(fd, iov[index].iov_base, requested, offset);
        if (result > 0 && (size_t)result < total) {
            record_event("short-write\n");
        }
        return result;
    }
    return real_pwrite64(fd, "", 0, offset);
}

ssize_t pwritev64(
    int fd,
    const struct iovec *iov,
    int iov_count,
    off64_t offset
) {
    pwritev64_fn real_pwritev64 = NULL;
    pwrite64_fn real_pwrite64 = NULL;
    load_symbol(&real_pwritev64, sizeof(real_pwritev64), "pwritev64");

    switch (action_for_call(fd)) {
        case fault_enospc:
            return fail_with(ENOSPC, "enospc\n");
        case fault_eio:
            return fail_with(EIO, "io-error\n");
        case fault_short:
            load_symbol(&real_pwrite64, sizeof(real_pwrite64), "pwrite64");
            return partial_pwritev64(
                real_pwrite64, fd, iov, iov_count, offset);
        case fault_none:
            return real_pwritev64(fd, iov, iov_count, offset);
    }
    return fail_with(EIO, "invalid-action\n");
}
