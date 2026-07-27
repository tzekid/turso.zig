const std = @import("std");
const status_mod = @import("status.zig");
const value_mod = @import("value.zig");

pub const Error = status_mod.Error || error{
    InvalidParameterName,
    AmbiguousParameter,
    DuplicateParameter,
    MissingParameter,
    UnusedField,
};

pub const NamedBinding = struct {
    name: []const u8,
    value: value_mod.Value,
};

pub const ParameterInfo = struct {
    /// Native parameter positions are one-based.
    position: usize,
    /// Includes the SQL prefix. Anonymous `?` slots have no name.
    name: ?[]u8,

    pub fn deinit(self: *ParameterInfo, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.name = null;
    }
};

pub fn validateSqlName(name: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InteriorNul;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    if (name.len < 2) return error.InvalidParameterName;
    switch (name[0]) {
        ':', '@', '$' => {},
        '?' => {
            for (name[1..]) |byte| {
                if (!std.ascii.isDigit(byte)) return error.InvalidParameterName;
            }
        },
        else => return error.InvalidParameterName,
    }
}

/// Strip `:`, `@`, or `$` for Zig struct-field matching. Numbered parameters
/// intentionally have no bare-field form.
pub fn bareName(name: []const u8) Error![]const u8 {
    try validateSqlName(name);
    return switch (name[0]) {
        ':', '@', '$' => name[1..],
        else => error.InvalidParameterName,
    };
}
