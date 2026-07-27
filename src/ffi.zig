//! Shared native status/error handling for the safe wrapper.
const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");

pub const Error = status_mod.Error;
pub const Control = status_mod.Control;
pub const Diagnostics = diagnostics_mod.Diagnostics;

pub const NativeError = [*c]const u8;

/// Interpret a native result, preserving its allocated message before freeing
/// it. The message is released on every path, including successful and unknown
/// status paths.
pub fn result(
    native_status: raw.turso_status_code_t,
    native_error: NativeError,
    diagnostics: ?*Diagnostics,
) Error!Control {
    defer if (native_error != null) raw.turso_str_deinit(native_error);

    const status = status_mod.Status.fromRaw(native_status) catch {
        setWrapperError(diagnostics, "native Turso library returned a status outside the u32 ABI range");
        return error.UnexpectedStatus;
    };
    const control = status.classify() catch |err| {
        if (diagnostics) |detail| {
            if (native_error != null) {
                detail.set(status, std.mem.sliceTo(native_error, 0));
            } else {
                detail.set(status, status.name());
            }
        }
        return err;
    };

    if (diagnostics) |detail| detail.clear();
    return control;
}

/// Require one particular non-error control status.
pub fn expect(
    native_status: raw.turso_status_code_t,
    native_error: NativeError,
    expected: Control,
    diagnostics: ?*Diagnostics,
    unexpected_detail: []const u8,
) Error!void {
    const actual = try result(native_status, native_error, diagnostics);
    if (actual != expected) {
        setWrapperError(diagnostics, unexpected_detail);
        return error.InvalidState;
    }
}

/// Bind functions cannot return a native message, so preserve a concise safe
/// wrapper message if their status is an error or an unexpected control value.
pub fn expectWithoutMessage(
    native_status: raw.turso_status_code_t,
    expected: Control,
    diagnostics: ?*Diagnostics,
    failure_detail: []const u8,
) Error!void {
    const status = status_mod.Status.fromRaw(native_status) catch {
        setWrapperError(diagnostics, failure_detail);
        return error.UnexpectedStatus;
    };
    const actual = status.classify() catch |err| {
        if (diagnostics) |detail| detail.set(status, failure_detail);
        return err;
    };
    if (actual != expected) {
        setWrapperError(diagnostics, failure_detail);
        return error.InvalidState;
    }
    if (diagnostics) |detail| detail.clear();
}

pub fn setWrapperError(diagnostics: ?*Diagnostics, detail: []const u8) void {
    if (diagnostics) |value| value.setWrapperError(detail);
}
