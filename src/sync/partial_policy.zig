const std = @import("std");

pub const Error = error{UnsupportedPartialBootstrap};

/// The pinned sync SDK Kit selects sparse persistent I/O only on Linux.
/// Its exact `:memory:` path uses MemoryIO and does not require file holes.
pub fn validate(
    path: []const u8,
    partial_bootstrap: bool,
    target_os: std.Target.Os.Tag,
) Error!void {
    if (!partial_bootstrap or
        target_os == .linux or
        std.mem.eql(u8, path, ":memory:"))
    {
        return;
    }
    return error.UnsupportedPartialBootstrap;
}

test "partial bootstrap target policy distinguishes memory and file storage" {
    const unsupported_targets = [_]std.Target.Os.Tag{
        .macos,
        .windows,
        .freebsd,
    };

    try validate("partial.db", true, .linux);
    try validate(":memory:", true, .macos);
    for (unsupported_targets) |target_os| {
        try std.testing.expectError(
            error.UnsupportedPartialBootstrap,
            validate("partial.db", true, target_os),
        );
    }
    try validate("partial.db", false, .windows);
}
