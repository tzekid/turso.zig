//! Stable, raw-layer-independent interpretation of Turso SDK Kit status codes.
//!
//! `Status` deliberately has a non-exhaustive integer representation. This lets
//! callers retain an unknown code from a newer native library and report
//! `error.UnexpectedStatus` instead of invoking undefined behavior.
const std = @import("std");

/// Errors surfaced by the safe API. Native status failures and wrapper-side
/// validation failures share one stable error set so public operations compose.
pub const Error = error{
    Busy,
    BusySnapshot,
    Interrupt,
    TursoFailure,
    Misuse,
    Constraint,
    ReadOnly,
    DatabaseFull,
    NotDatabase,
    Corrupt,
    Io,
    UnexpectedStatus,

    OutOfMemory,
    InteriorNul,
    InvalidUtf8,
    InvalidState,
    ParameterCountMismatch,
    ParameterNotFound,
    ColumnOutOfBounds,
    TypeMismatch,
    IntegerOverflow,
    NoRow,
    Unsupported,
    VersionMismatch,
    AlreadySetup,
};

/// All status codes defined by `sdk-kit/turso.h` at the pinned Turso revision.
/// Unknown integer values remain representable through the `_` field.
pub const Status = enum(u32) {
    ok = 0,
    done = 1,
    row = 2,
    io = 3,
    busy = 4,
    interrupt = 5,
    busy_snapshot = 6,
    failure = 127,
    misuse = 128,
    constraint = 129,
    read_only = 130,
    database_full = 131,
    not_database = 132,
    corrupt = 133,
    io_error = 134,
    _,

    pub fn fromInt(code: anytype) Error!Status {
        switch (@typeInfo(@TypeOf(code))) {
            .int, .comptime_int => {},
            else => @compileError("Turso status must be an integer"),
        }
        const value = std.math.cast(u32, code) orelse return error.UnexpectedStatus;
        return @fromBackingInt(@intCast(value));
    }

    /// Convert either an integer or a C/native enum value. Kept separate from
    /// `fromInt` so accidental non-integer inputs fail at compile time.
    pub fn fromRaw(code: anytype) Error!Status {
        return switch (@typeInfo(@TypeOf(code))) {
            .@"enum" => fromInt(@backingInt(code)),
            .int, .comptime_int => fromInt(code),
            else => @compileError("Turso status must be an integer or enum"),
        };
    }

    pub fn toInt(self: Status) u32 {
        return @backingInt(self);
    }

    /// Classify a status into a successful control result or a stable error.
    pub fn classify(self: Status) Error!Control {
        return switch (self) {
            .ok => .ok,
            .done => .done,
            .row => .row,
            .io => .io,
            .busy => error.Busy,
            .busy_snapshot => error.BusySnapshot,
            .interrupt => error.Interrupt,
            .failure => error.TursoFailure,
            .misuse => error.Misuse,
            .constraint => error.Constraint,
            .read_only => error.ReadOnly,
            .database_full => error.DatabaseFull,
            .not_database => error.NotDatabase,
            .corrupt => error.Corrupt,
            .io_error => error.Io,
            _ => error.UnexpectedStatus,
        };
    }

    pub fn isControl(self: Status) bool {
        return switch (self) {
            .ok, .done, .row, .io => true,
            else => false,
        };
    }

    /// A stable display name. Unknown values are reported without pretending
    /// that they are one of the statuses known by this package version.
    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .done => "done",
            .row => "row",
            .io => "io",
            .busy => "busy",
            .busy_snapshot => "busy_snapshot",
            .interrupt => "interrupt",
            .failure => "failure",
            .misuse => "misuse",
            .constraint => "constraint",
            .read_only => "read_only",
            .database_full => "database_full",
            .not_database => "not_database",
            .corrupt => "corrupt",
            .io_error => "io_error",
            _ => "unknown",
        };
    }
};

/// Non-error state-machine results returned by the native API.
pub const Control = enum {
    ok,
    done,
    row,
    io,
};

/// Convenience for call sites that have only the native integer code.
pub fn classify(code: anytype) Error!Control {
    return (try Status.fromRaw(code)).classify();
}
