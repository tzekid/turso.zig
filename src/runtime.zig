//! Process-global SDK setup and runtime-version verification.
const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const ffi = @import("ffi.zig");
const build_options = @import("turso_build_options");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Error = status_mod.Error;

pub const LogLevel = enum {
    error_level,
    warn,
    info,
    debug,
    trace,

    fn nativeName(self: LogLevel) [:0]const u8 {
        return switch (self) {
            .error_level => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }
};

pub const TracingLevel = enum {
    error_level,
    warn,
    info,
    debug,
    trace,
    unknown,
};

/// Borrowed log event. Every slice is valid only for the logger invocation.
pub const Log = struct {
    message: []const u8,
    target: []const u8,
    file: []const u8,
    timestamp: u64,
    line: usize,
    level: TracingLevel,
};

/// Must be thread-safe, must return normally, and must copy any retained data.
/// A panic cannot be caught safely and must never cross the C callback boundary.
pub const Logger = *const fn (Log) void;

pub const SetupOptions = struct {
    level: ?LogLevel = null,
    logger: ?Logger = null,
    diagnostics: ?*Diagnostics = null,
};

var setup_state = std.atomic.Value(u8).init(0);
var logger_address = std.atomic.Value(usize).init(0);

/// Configure Turso's process-global tracing subscriber exactly once through
/// this wrapper. Call before creating worker threads or opening databases.
pub fn setup(options: SetupOptions) Error!void {
    // `turso_version` is the sole compatibility probe allowed before any
    // configuration struct or callback crosses the pinned C ABI boundary.
    try verifyRuntimeVersion(options.diagnostics);
    if (setup_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        ffi.setWrapperError(options.diagnostics, "Turso process-global setup is already in progress or completed");
        return error.AlreadySetup;
    }
    errdefer setup_state.store(0, .release);

    logger_address.store(if (options.logger) |callback| @intFromPtr(callback) else 0, .release);
    errdefer logger_address.store(0, .release);

    const level_name = if (options.level) |level| level.nativeName() else null;
    const native_config = raw.turso_config_t{
        .logger = if (options.logger != null) logTrampoline else null,
        .log_level = if (level_name) |name| name.ptr else null,
    };
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_setup(&native_config, &native_error);
    try ffi.expect(native_status, native_error, .ok, options.diagnostics, "turso_setup returned an unexpected control status");
    setup_state.store(2, .release);
}

/// The native version string has static process lifetime.
pub fn runtimeVersion() Error![]const u8 {
    const native = raw.turso_version();
    if (native == null) return error.InvalidState;
    return std.mem.sliceTo(native, 0);
}

/// The exact SDK Kit version selected by this build.
pub fn expectedRuntimeVersion() []const u8 {
    return build_options.expected_runtime_version;
}

/// Require the exact SDK Kit release selected by this build.
pub fn verifyRuntimeVersion(diagnostics: ?*Diagnostics) Error!void {
    const actual = runtimeVersion() catch |err| {
        ffi.setWrapperError(diagnostics, "native Turso library returned a null version string");
        return err;
    };
    if (!std.mem.eql(u8, actual, expectedRuntimeVersion())) {
        ffi.setWrapperError(diagnostics, "native Turso version does not match the SDK Kit version selected by this build");
        return error.VersionMismatch;
    }
    if (diagnostics) |detail| detail.clear();
}

fn logTrampoline(native_log: [*c]const raw.turso_log_t) callconv(.c) void {
    if (native_log == null) return;
    const address = logger_address.load(.acquire);
    if (address == 0) return;
    const callback: Logger = @ptrFromInt(address);
    const native = native_log.*;
    callback(.{
        .message = borrowedCString(native.message),
        .target = borrowedCString(native.target),
        .file = borrowedCString(native.file),
        .timestamp = native.timestamp,
        .line = native.line,
        .level = tracingLevel(native.level),
    });
}

fn borrowedCString(pointer: [*c]const u8) []const u8 {
    return if (pointer == null) &.{} else std.mem.sliceTo(pointer, 0);
}

fn tracingLevel(level: raw.turso_tracing_level_t) TracingLevel {
    if (level == raw.TURSO_TRACING_LEVEL_ERROR) return .error_level;
    if (level == raw.TURSO_TRACING_LEVEL_WARN) return .warn;
    if (level == raw.TURSO_TRACING_LEVEL_INFO) return .info;
    if (level == raw.TURSO_TRACING_LEVEL_DEBUG) return .debug;
    if (level == raw.TURSO_TRACING_LEVEL_TRACE) return .trace;
    return .unknown;
}

test "native tracing levels map exhaustively and tolerate future values" {
    try std.testing.expectEqualStrings("error", LogLevel.error_level.nativeName());
    try std.testing.expectEqualStrings("warn", LogLevel.warn.nativeName());
    try std.testing.expectEqualStrings("info", LogLevel.info.nativeName());
    try std.testing.expectEqualStrings("debug", LogLevel.debug.nativeName());
    try std.testing.expectEqualStrings("trace", LogLevel.trace.nativeName());
    try std.testing.expectEqual(TracingLevel.error_level, tracingLevel(raw.TURSO_TRACING_LEVEL_ERROR));
    try std.testing.expectEqual(TracingLevel.warn, tracingLevel(raw.TURSO_TRACING_LEVEL_WARN));
    try std.testing.expectEqual(TracingLevel.info, tracingLevel(raw.TURSO_TRACING_LEVEL_INFO));
    try std.testing.expectEqual(TracingLevel.debug, tracingLevel(raw.TURSO_TRACING_LEVEL_DEBUG));
    try std.testing.expectEqual(TracingLevel.trace, tracingLevel(raw.TURSO_TRACING_LEVEL_TRACE));
    try std.testing.expectEqual(TracingLevel.unknown, tracingLevel(@as(raw.turso_tracing_level_t, 0)));
    try std.testing.expectEqual(TracingLevel.unknown, tracingLevel(@as(raw.turso_tracing_level_t, 127)));
}

test "logger C strings treat null as empty and preserve static bytes" {
    try std.testing.expectEqual(@as(usize, 0), borrowedCString(null).len);
    try std.testing.expectEqualStrings("logger-bytes", borrowedCString("logger-bytes"));
}
