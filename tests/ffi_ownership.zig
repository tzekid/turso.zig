const std = @import("std");
const ffi = @import("ffi");
const raw = @import("turso_c");

extern fn turso_zig_error_reset() void;
extern fn turso_zig_error_new() [*c]const u8;
extern fn turso_zig_error_allocations() usize;
extern fn turso_zig_error_deinits() usize;

test "native error strings are copied and released exactly once for every status class" {
    const failures = [_]raw.turso_status_code_t{
        raw.TURSO_ERROR,
        raw.TURSO_MISUSE,
        raw.TURSO_CONSTRAINT,
        raw.TURSO_READONLY,
        raw.TURSO_DATABASE_FULL,
        raw.TURSO_NOTADB,
        raw.TURSO_CORRUPT,
        raw.TURSO_IOERR,
    };

    turso_zig_error_reset();
    var diagnostics = ffi.Diagnostics{};
    for (failures, 0..) |status, index| {
        const native_error = turso_zig_error_new();
        try std.testing.expect(native_error != null);
        try std.testing.expectError(statusExpectedError(status), ffi.result(status, native_error, &diagnostics));
        try std.testing.expectEqualStrings("owned native error", diagnostics.text());
        try std.testing.expectEqual(index + 1, turso_zig_error_deinits());
    }
    try std.testing.expectEqual(turso_zig_error_allocations(), turso_zig_error_deinits());

    const success_error = turso_zig_error_new();
    try std.testing.expectEqual(ffi.Control.ok, try ffi.result(raw.TURSO_OK, success_error, &diagnostics));
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expectEqual(turso_zig_error_allocations(), turso_zig_error_deinits());

    const before = turso_zig_error_deinits();
    try std.testing.expectError(error.Constraint, ffi.result(raw.TURSO_CONSTRAINT, null, &diagnostics));
    try std.testing.expectEqual(before, turso_zig_error_deinits());
    try std.testing.expectEqualStrings("constraint", diagnostics.text());
}

fn statusExpectedError(status: raw.turso_status_code_t) anyerror {
    if (status == raw.TURSO_ERROR) return error.TursoFailure;
    if (status == raw.TURSO_MISUSE) return error.Misuse;
    if (status == raw.TURSO_CONSTRAINT) return error.Constraint;
    if (status == raw.TURSO_READONLY) return error.ReadOnly;
    if (status == raw.TURSO_DATABASE_FULL) return error.DatabaseFull;
    if (status == raw.TURSO_NOTADB) return error.NotDatabase;
    if (status == raw.TURSO_CORRUPT) return error.Corrupt;
    if (status == raw.TURSO_IOERR) return error.Io;
    unreachable;
}
