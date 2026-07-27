const std = @import("std");
const status = @import("status");

test "all native control statuses classify exactly" {
    try std.testing.expectEqual(status.Control.ok, try status.classify(0));
    try std.testing.expectEqual(status.Control.done, try status.classify(1));
    try std.testing.expectEqual(status.Control.row, try status.classify(2));
    try std.testing.expectEqual(status.Control.io, try status.classify(3));
}

test "all native failures have stable Zig errors" {
    const cases = [_]struct { code: u32, expected: status.Error }{
        .{ .code = 4, .expected = error.Busy },
        .{ .code = 5, .expected = error.Interrupt },
        .{ .code = 6, .expected = error.BusySnapshot },
        .{ .code = 127, .expected = error.TursoFailure },
        .{ .code = 128, .expected = error.Misuse },
        .{ .code = 129, .expected = error.Constraint },
        .{ .code = 130, .expected = error.ReadOnly },
        .{ .code = 131, .expected = error.DatabaseFull },
        .{ .code = 132, .expected = error.NotDatabase },
        .{ .code = 133, .expected = error.Corrupt },
        .{ .code = 134, .expected = error.Io },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, status.classify(case.code));
    }
}

test "unknown status survives round trip and is rejected" {
    const unknown = try status.Status.fromInt(999);
    try std.testing.expectEqual(@as(u32, 999), unknown.toInt());
    try std.testing.expectEqualStrings("unknown", unknown.name());
    try std.testing.expectError(error.UnexpectedStatus, unknown.classify());
}

test "native enum status is accepted without a raw-layer dependency" {
    const FakeNative = enum(c_uint) { ok = 0, busy = 4 };
    try std.testing.expectEqual(status.Status.busy, try status.Status.fromRaw(FakeNative.busy));
    try std.testing.expectError(error.Busy, status.classify(FakeNative.busy));
}

test "out-of-range signed and wide statuses never trap" {
    try std.testing.expectError(error.UnexpectedStatus, status.Status.fromInt(@as(i64, -1)));
    try std.testing.expectError(
        error.UnexpectedStatus,
        status.Status.fromInt(@as(u64, std.math.maxInt(u32)) + 1),
    );
    const NegativeNative = enum(i32) { invalid = -1 };
    try std.testing.expectError(error.UnexpectedStatus, status.Status.fromRaw(NegativeNative.invalid));
}
