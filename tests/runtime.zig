const std = @import("std");
const turso = @import("turso");

test "runtime version exactly matches the pinned SDK Kit" {
    try turso.verifyRuntimeVersion(null);
    try std.testing.expectEqualStrings(turso.expectedRuntimeVersion(), try turso.runtimeVersion());
}

test "process-global setup succeeds once and rejects replacement" {
    var diagnostics = turso.Diagnostics{};
    try turso.setup(.{ .level = .info, .diagnostics = &diagnostics });
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);
    try std.testing.expectError(error.AlreadySetup, turso.setup(.{ .diagnostics = &diagnostics }));
    try std.testing.expect(diagnostics.text().len != 0);
}
