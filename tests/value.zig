const std = @import("std");
const value_mod = @import("value");

const Blob = value_mod.Blob;
const Text = value_mod.Text;
const Value = value_mod.Value;

test "binding conversion is explicit about text and blob" {
    const text = try Value.init("hello");
    try std.testing.expectEqualStrings("hello", try text.asText());
    try std.testing.expectEqual(Value.Kind.text, text.kind());

    var mutable_text = [_]u8{ 'z', 'i', 'g' };
    const mutable_slice: []u8 = &mutable_text;
    try std.testing.expectEqualStrings("zig", try (try Value.init(mutable_slice)).asText());

    const arbitrary = [_]u8{ 0xff, 0x00, 0x80 };
    const blob = try Value.init(Blob.init(&arbitrary));
    try std.testing.expectEqualSlices(u8, &arbitrary, (try blob.asBlob()).bytes);
    try std.testing.expectError(error.InvalidUtf8, Text.init(&arbitrary));
    try std.testing.expectError(error.InvalidUtf8, Value.init(@as([]const u8, &arbitrary)));
}

test "null optionals integers floats and bool convert without truncation" {
    const absent: ?u32 = null;
    try std.testing.expectEqual(Value.null_value, try Value.init(absent));
    try std.testing.expectEqual(@as(i64, 1), try (try Value.init(true)).asInteger());
    try std.testing.expectEqual(@as(i64, 42), try (try Value.init(@as(u8, 42))).asInteger());
    try std.testing.expectEqual(@as(f64, 1.5), try (try Value.init(@as(f32, 1.5))).asReal());
    try std.testing.expectError(error.IntegerOverflow, Value.init(@as(u64, std.math.maxInt(u64))));
}

test "typed decoding checks null type and integer ranges" {
    const integer: Value = .{ .integer = 255 };
    try std.testing.expectEqual(@as(u8, 255), try integer.get(u8));
    try std.testing.expectError(error.IntegerOverflow, integer.get(i8));
    try std.testing.expectError(error.TypeMismatch, integer.get([]const u8));

    const null_value: Value = .null_value;
    try std.testing.expect(null_value.isNull());
    try std.testing.expectEqual(@as(?u8, null), try null_value.get(?u8));
    try std.testing.expectError(error.TypeMismatch, null_value.get(u8));
}

test "bool decoding accepts only canonical zero and one" {
    try std.testing.expectEqual(false, try (Value{ .integer = 0 }).get(bool));
    try std.testing.expectEqual(true, try (Value{ .integer = 1 }).get(bool));
    try std.testing.expectError(error.IntegerOverflow, (Value{ .integer = 2 }).get(bool));
}

test "narrow float decoding is exact" {
    try std.testing.expectEqual(@as(f32, 1.5), try (Value{ .real = 1.5 }).get(f32));
    try std.testing.expectError(error.IntegerOverflow, (Value{ .real = 0.1 }).get(f32));
    try std.testing.expectError(error.TypeMismatch, (Value{ .integer = 1 }).get(f64));
}

test "owned values copy clone and release storage" {
    const allocator = std.testing.allocator;
    const source = [_]u8{ 1, 2, 3, 4 };

    var owned = try (Value{ .blob = &source }).toOwned(allocator);
    defer owned.deinit(allocator);
    var clone = try owned.clone(allocator);
    defer clone.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &source, (try owned.get(Blob)).bytes);
    switch (owned) {
        .blob => |bytes| bytes[0] = 9,
        else => unreachable,
    }
    try std.testing.expectEqual(@as(u8, 1), (try clone.get(Blob)).bytes[0]);
}
