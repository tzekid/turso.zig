const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const value_mod = @import("value.zig");
const decode_mod = @import("decode.zig");

pub const ValueRef = value_mod.ValueRef;
pub const OwnedValue = value_mod.OwnedValue;
pub const DecodeError = decode_mod.Error || error{
    ColumnCountMismatch,
    MissingColumn,
    AmbiguousColumn,
};

pub const DecodeMode = enum { by_position, by_name };

pub const DecodeOptions = struct {
    mode: DecodeMode = .by_position,
    allow_extra_columns: bool = false,
};

pub const ColumnKind = union(enum) {
    none,
    builtin,
    custom,
    domain,
    struct_type,
    union_type,
    unknown: i32,
};

pub const ColumnInfo = struct {
    index: usize,
    name: []u8,
    declared_type: ?[]u8,
    kind: ColumnKind,
    declared_name: ?[]u8,
    base_type: ?[]u8,
    array_dimensions: u32,
    owned: bool = true,

    pub fn deinit(self: *ColumnInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.name);
        if (self.declared_type) |value| allocator.free(value);
        if (self.declared_name) |value| allocator.free(value);
        if (self.base_type) |value| allocator.free(value);
        self.declared_type = null;
        self.declared_name = null;
        self.base_type = null;
        self.name = &.{};
        self.owned = false;
    }
};

pub const AutocommitExpectation = enum {
    enabled,
    disabled,
    any,
};

/// Heap-stable per-connection statement control. Connection owns this storage;
/// Statement and borrowed Row values only retain pointers to it.
pub const OperationControl = struct {
    active: bool = false,
    statement_alive: bool = false,
    generation: u64 = 0,
    aggregate_cleanup_context: ?*anyopaque = null,
    aggregate_cleanup: ?*const fn (*anyopaque) void = null,
    autocommit_context: ?*anyopaque = null,
    autocommit_check: ?*const fn (*anyopaque, AutocommitExpectation) bool = null,
    autocommit_expectation: AutocommitExpectation = .enabled,

    pub fn invalidate(self: *OperationControl) void {
        self.generation +%= 1;
    }

    pub fn cleanupAggregates(self: *OperationControl) void {
        const cleanup = self.aggregate_cleanup orelse return;
        cleanup(self.aggregate_cleanup_context.?);
    }

    pub fn autocommitInvariantHolds(self: *OperationControl) bool {
        if (self.autocommit_expectation == .any) return true;
        const check = self.autocommit_check orelse return false;
        return check(self.autocommit_context.?, self.autocommit_expectation);
    }
};

/// Borrowed view of the current statement row. Column indices are zero-based.
/// The row and any returned text/blob slices expire at the next Rows operation.
pub const Row = struct {
    statement: *raw.turso_statement_t,
    column_count: usize,
    control: *const OperationControl,
    generation: u64,

    pub fn columnCount(self: Row) usize {
        return self.column_count;
    }

    pub fn value(self: Row, index: usize) status_mod.Error!ValueRef {
        try self.ensureValid();
        if (index >= self.column_count) return error.ColumnOutOfBounds;

        const kind = raw.turso_statement_row_value_kind(self.statement, index);
        if (kind == raw.TURSO_TYPE_NULL) return .null_value;
        if (kind == raw.TURSO_TYPE_INTEGER) {
            return .{ .integer = raw.turso_statement_row_value_int(self.statement, index) };
        }
        if (kind == raw.TURSO_TYPE_REAL) {
            return .{ .real = raw.turso_statement_row_value_double(self.statement, index) };
        }
        if (kind == raw.TURSO_TYPE_TEXT or kind == raw.TURSO_TYPE_BLOB) {
            const native_len = raw.turso_statement_row_value_bytes_count(self.statement, index);
            if (native_len < 0) return error.InvalidState;
            const len = std.math.cast(usize, native_len) orelse return error.IntegerOverflow;
            const bytes: []const u8 = if (len == 0) &.{} else blk: {
                const native_ptr = raw.turso_statement_row_value_bytes_ptr(self.statement, index);
                if (native_ptr == null) return error.InvalidState;
                const ptr: [*]const u8 = @ptrCast(native_ptr);
                break :blk ptr[0..len];
            };
            return if (kind == raw.TURSO_TYPE_TEXT) .{ .text = bytes } else .{ .blob = bytes };
        }
        return error.TypeMismatch;
    }

    pub fn get(self: Row, comptime T: type, index: usize) status_mod.Error!T {
        return (try self.value(index)).get(T);
    }

    pub fn getByName(self: Row, comptime T: type, name: []const u8) DecodeError!T {
        return self.get(T, try self.findColumn(name));
    }

    /// Decode into a tuple of mutable pointers without allocation.
    pub fn scan(self: Row, destinations: anytype) DecodeError!void {
        const info = @typeInfo(@TypeOf(destinations));
        if (info != .@"struct" or !info.@"struct".is_tuple) return error.TypeMismatch;
        const fields = info.@"struct".fields;
        if (fields.len != self.column_count) return error.ColumnCountMismatch;
        inline for (fields, 0..) |field, index| {
            const Pointer = @typeInfo(field.type);
            if (Pointer != .pointer or Pointer.pointer.size != .one or Pointer.pointer.is_const) {
                return error.TypeMismatch;
            }
            const destination = @field(destinations, field.name);
            destination.* = try decode_mod.valueAs(Pointer.pointer.child, try self.value(index), null);
        }
    }

    /// Decode a tuple/struct by position or a named struct by exact column name.
    /// Owned `[]u8` and `OwnedValue` fields require an allocator and are cleaned
    /// up if a later field fails.
    pub fn decode(
        self: Row,
        comptime T: type,
        allocator: ?std.mem.Allocator,
        options: DecodeOptions,
    ) DecodeError!T {
        const info = @typeInfo(T);
        if (info != .@"struct") return error.TypeMismatch;
        const fields = info.@"struct".fields;
        if (self.column_count < fields.len) return error.MissingColumn;
        if (!options.allow_extra_columns and self.column_count != fields.len) {
            return error.ColumnCountMismatch;
        }
        if (info.@"struct".is_tuple and options.mode == .by_name) return error.TypeMismatch;

        var result: T = undefined;
        var initialized: usize = 0;
        errdefer inline for (fields, 0..) |field, index| {
            if (index < initialized) {
                decode_mod.deinitValue(field.type, &@field(result, field.name), allocator);
            }
        };

        inline for (fields, 0..) |field, position| {
            const index = if (options.mode == .by_position)
                position
            else
                try self.findColumn(field.name);
            @field(result, field.name) = try decode_mod.valueAs(field.type, try self.value(index), allocator);
            initialized += 1;
        }
        return result;
    }

    pub fn toOwned(self: Row, allocator: std.mem.Allocator, index: usize) status_mod.Error!OwnedValue {
        return (try self.value(index)).toOwned(allocator);
    }

    fn findColumn(self: Row, name: []const u8) DecodeError!usize {
        try self.ensureValid();
        var found: ?usize = null;
        var index: usize = 0;
        while (index < self.column_count) : (index += 1) {
            const native_name = raw.turso_statement_column_name(self.statement, index);
            if (native_name == null) return error.InvalidState;
            defer raw.turso_str_deinit(native_name);
            if (std.mem.eql(u8, name, std.mem.sliceTo(native_name, 0))) {
                if (found != null) return error.AmbiguousColumn;
                found = index;
            }
        }
        return found orelse error.MissingColumn;
    }

    fn ensureValid(self: Row) status_mod.Error!void {
        if (!self.control.statement_alive or self.control.generation != self.generation) {
            return error.InvalidState;
        }
    }
};

pub fn init(
    statement: *raw.turso_statement_t,
    column_count: usize,
    control: *const OperationControl,
) Row {
    return .{
        .statement = statement,
        .column_count = column_count,
        .control = control,
        .generation = control.generation,
    };
}

pub fn copyColumnInfo(
    allocator: std.mem.Allocator,
    statement: *raw.turso_statement_t,
    index: usize,
) status_mod.Error!ColumnInfo {
    const native_name = raw.turso_statement_column_name(statement, index);
    if (native_name == null) return error.InvalidState;
    const name = try copyRequiredNativeString(allocator, native_name);
    errdefer allocator.free(name);

    const declared_type = try copyOptionalNativeString(
        allocator,
        raw.turso_statement_column_decltype(statement, index),
    );
    errdefer if (declared_type) |value| allocator.free(value);
    const declared_name = try copyOptionalNativeString(
        allocator,
        raw.turso_statement_column_declared_name(statement, index),
    );
    errdefer if (declared_name) |value| allocator.free(value);
    const base_type = try copyOptionalNativeString(
        allocator,
        raw.turso_statement_column_base_type(statement, index),
    );
    errdefer if (base_type) |value| allocator.free(value);

    const native_kind: i32 = @intCast(raw.turso_statement_column_kind(statement, index));
    const kind: ColumnKind = switch (native_kind) {
        -1 => .none,
        0 => .builtin,
        1 => .custom,
        2 => .domain,
        3 => .struct_type,
        4 => .union_type,
        else => .{ .unknown = native_kind },
    };
    return .{
        .index = index,
        .name = name,
        .declared_type = declared_type,
        .kind = kind,
        .declared_name = declared_name,
        .base_type = base_type,
        .array_dimensions = raw.turso_statement_column_array_dimensions(statement, index),
    };
}

fn copyRequiredNativeString(
    allocator: std.mem.Allocator,
    native: [*c]const u8,
) status_mod.Error![]u8 {
    if (native == null) return error.InvalidState;
    defer raw.turso_str_deinit(native);
    return try allocator.dupe(u8, std.mem.sliceTo(native, 0));
}

fn copyOptionalNativeString(
    allocator: std.mem.Allocator,
    native: [*c]const u8,
) status_mod.Error!?[]u8 {
    if (native == null) return null;
    return try copyRequiredNativeString(allocator, native);
}
