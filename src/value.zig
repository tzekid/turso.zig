const std = @import("std");

pub const ConversionError = error{
    InvalidUtf8,
    TypeMismatch,
    IntegerOverflow,
};

/// Explicit SQL TEXT input. Validation occurs when converting it to `Value`.
pub const Text = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) ConversionError!Text {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return .{ .bytes = bytes };
    }

    pub fn slice(self: Text) []const u8 {
        return self.bytes;
    }
};

/// Explicit SQL BLOB input. Its bytes are arbitrary and are never UTF-8 checked.
pub const Blob = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Blob {
        return .{ .bytes = bytes };
    }

    pub fn slice(self: Blob) []const u8 {
        return self.bytes;
    }
};

/// Borrowed SQL value. Text and blob storage remains owned by the producer.
/// Values obtained from a row are generally invalidated by the next statement
/// step, reset, finalize, or deinit.
pub const Value = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub const Kind = enum { null_value, integer, real, text, blob };

    pub fn kind(self: Value) Kind {
        return switch (self) {
            .null_value => .null_value,
            .integer => .integer,
            .real => .real,
            .text => .text,
            .blob => .blob,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_value;
    }

    /// Convert a binding input to a borrowed SQL value. Byte slices default to
    /// TEXT; callers must use `Blob` to opt into BLOB semantics.
    pub fn init(input: anytype) ConversionError!Value {
        const T = @TypeOf(input);
        if (T == Value) return input;
        if (T == OwnedValue) return input.ref();
        if (T == Text) {
            if (!std.unicode.utf8ValidateSlice(input.bytes)) return error.InvalidUtf8;
            return .{ .text = input.bytes };
        }
        if (T == Blob) return .{ .blob = input.bytes };

        return switch (@typeInfo(T)) {
            .null => .null_value,
            .optional => if (input) |value| Value.init(value) else .null_value,
            .bool => .{ .integer = if (input) 1 else 0 },
            .int, .comptime_int => .{ .integer = std.math.cast(i64, input) orelse return error.IntegerOverflow },
            .float, .comptime_float => floatInput(input),
            .pointer => |pointer| blk: {
                const bytes: []const u8 = switch (pointer.size) {
                    .slice => if (pointer.child == u8) input else return error.TypeMismatch,
                    .one => switch (@typeInfo(pointer.child)) {
                        .array => |array| if (array.child == u8) input[0..] else return error.TypeMismatch,
                        else => return error.TypeMismatch,
                    },
                    else => return error.TypeMismatch,
                };
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
                break :blk .{ .text = bytes };
            },
            else => error.TypeMismatch,
        };
    }

    pub fn toOwned(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!OwnedValue {
        return switch (self) {
            .null_value => .null_value,
            .integer => |value| .{ .integer = value },
            .real => |value| .{ .real = value },
            .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
        };
    }

    pub fn asInteger(self: Value) ConversionError!i64 {
        return switch (self) {
            .integer => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn asReal(self: Value) ConversionError!f64 {
        return switch (self) {
            .real => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn asText(self: Value) ConversionError![]const u8 {
        return switch (self) {
            .text => |bytes| bytes,
            else => error.TypeMismatch,
        };
    }

    pub fn asBlob(self: Value) ConversionError!Blob {
        return switch (self) {
            .blob => |bytes| .{ .bytes = bytes },
            else => error.TypeMismatch,
        };
    }

    /// Decode into a non-allocating Zig type. Supported destinations are
    /// optionals, bool, integers, floats, `[]const u8`, `Text`, `Blob`, and
    /// `Value`. Owned byte results require `toOwned` instead.
    pub fn get(self: Value, comptime T: type) ConversionError!T {
        if (T == Value) return self;
        if (T == Text) return .{ .bytes = try self.asText() };
        if (T == Blob) return try self.asBlob();
        if (T == []const u8) return try self.asText();

        return switch (@typeInfo(T)) {
            .optional => |optional| if (self == .null_value)
                null
            else
                try self.get(optional.child),
            .bool => switch (self) {
                .integer => |value| switch (value) {
                    0 => false,
                    1 => true,
                    else => error.IntegerOverflow,
                },
                else => error.TypeMismatch,
            },
            .int => switch (self) {
                .integer => |value| std.math.cast(T, value) orelse error.IntegerOverflow,
                else => error.TypeMismatch,
            },
            .float => switch (self) {
                .real => |value| checkedFloatCast(T, value),
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }
};

pub const ValueRef = Value;

/// Independently owned SQL value. `deinit` must be called exactly once for text
/// and blob variants. As with allocator-owning Zig structs generally, copying an
/// `OwnedValue` does not duplicate its allocation; use `clone` when needed.
pub const OwnedValue = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,

    pub fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |bytes| allocator.free(bytes),
            .blob => |bytes| allocator.free(bytes),
            else => {},
        }
        self.* = .null_value;
    }

    pub fn ref(self: *const OwnedValue) ValueRef {
        return switch (self.*) {
            .null_value => .null_value,
            .integer => |value| .{ .integer = value },
            .real => |value| .{ .real = value },
            .text => |bytes| .{ .text = bytes },
            .blob => |bytes| .{ .blob = bytes },
        };
    }

    pub fn clone(self: *const OwnedValue, allocator: std.mem.Allocator) std.mem.Allocator.Error!OwnedValue {
        return self.ref().toOwned(allocator);
    }

    pub fn get(self: *const OwnedValue, comptime T: type) ConversionError!T {
        return self.ref().get(T);
    }
};

fn floatInput(input: anytype) ConversionError!Value {
    const T = @TypeOf(input);
    return switch (@typeInfo(T)) {
        .comptime_float => .{ .real = input },
        .float => |float| if (float.bits <= 64)
            .{ .real = @floatCast(input) }
        else
            error.TypeMismatch,
        else => unreachable,
    };
}

fn checkedFloatCast(comptime T: type, value: f64) ConversionError!T {
    if (T == f64) return value;

    const converted: T = @floatCast(value);
    if (std.math.isNan(value)) return converted;
    if (std.math.isInf(value)) {
        if (!std.math.isInf(converted) or std.math.signbit(value) != std.math.signbit(converted)) {
            return error.IntegerOverflow;
        }
        return converted;
    }
    if (!std.math.isFinite(converted)) return error.IntegerOverflow;
    if (@as(f64, @floatCast(converted)) != value) return error.IntegerOverflow;
    return converted;
}
