const std = @import("std");
const diagnostics_mod = @import("diagnostics");

const Diagnostics = diagnostics_mod.Diagnostics;

test "diagnostics records and clears without allocation" {
    var diagnostics = Diagnostics{};
    diagnostics.set(.constraint, "unique constraint failed");

    try std.testing.expectEqual(diagnostics_mod.Status.constraint, diagnostics.status);
    try std.testing.expectEqualStrings("unique constraint failed", diagnostics.text());
    try std.testing.expect(!diagnostics.truncated);

    diagnostics.clear();
    try std.testing.expectEqual(diagnostics_mod.Status.ok, diagnostics.status);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expect(!diagnostics.truncated);
}

test "diagnostics truncates deterministically at fixed capacity" {
    const input: [Diagnostics.capacity + 17]u8 = @splat('x');
    var diagnostics = Diagnostics{};
    diagnostics.set(.io_error, &input);

    try std.testing.expectEqual(@as(usize, Diagnostics.capacity), diagnostics.text().len);
    try std.testing.expect(diagnostics.truncated);
    for (diagnostics.text()) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
}

test "shorter replacement does not expose stale bytes" {
    var diagnostics = Diagnostics{};
    diagnostics.set(.failure, "a much longer previous diagnostic");
    diagnostics.setWrapperError("short");

    try std.testing.expectEqualStrings("short", diagnostics.text());
    try std.testing.expect(!diagnostics.truncated);
}
