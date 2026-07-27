const std = @import("std");
const builtin = @import("builtin");

pub const Vfs = union(enum) {
    automatic,
    memory,
    syscall,
    io_uring,
    experimental_win_iocp,
    custom: []const u8,

    pub fn name(self: Vfs) ?[]const u8 {
        return switch (self) {
            .automatic => null,
            .memory => "memory",
            .syscall => "syscall",
            .io_uring => "io_uring",
            .experimental_win_iocp => "experimental_win_iocp",
            .custom => |value| value,
        };
    }

    pub const ValidationError = error{
        UnsupportedVfs,
        InvalidVfsName,
    };

    /// Reject built-in backends that cannot exist on the compilation target.
    /// Custom names remain available for application-registered native VFSes.
    pub fn validateForTarget(self: Vfs) ValidationError!void {
        switch (self) {
            .io_uring => if (builtin.os.tag != .linux) return error.UnsupportedVfs,
            .experimental_win_iocp => if (builtin.os.tag != .windows) return error.UnsupportedVfs,
            .custom => |value| if (value.len == 0) return error.InvalidVfsName,
            else => {},
        }
    }
};

pub const FeatureSet = struct {
    views: bool = false,
    index_method: bool = false,
    custom_types: bool = false,
    autovacuum: bool = false,
    vacuum: bool = false,
    encryption: bool = false,
    attach: bool = false,
    generated_columns: bool = false,
    multiprocess_wal: bool = false,
    without_rowid: bool = false,
    extra: []const []const u8 = &.{},

    pub const RenderError = std.mem.Allocator.Error || error{InvalidFeatureName};

    pub fn render(self: FeatureSet, allocator: std.mem.Allocator) RenderError!?[]u8 {
        const known = [_]?[]const u8{
            if (self.views) "views" else null,
            if (self.index_method) "index_method" else null,
            if (self.custom_types) "custom_types" else null,
            if (self.autovacuum) "autovacuum" else null,
            if (self.vacuum) "vacuum" else null,
            if (self.encryption) "encryption" else null,
            if (self.attach) "attach" else null,
            if (self.generated_columns) "generated_columns" else null,
            if (self.multiprocess_wal) "multiprocess_wal" else null,
            if (self.without_rowid) "without_rowid" else null,
        };

        var count: usize = 0;
        var byte_len: usize = 0;
        for (known) |maybe_name| {
            if (maybe_name) |name| {
                count += 1;
                byte_len += name.len;
            }
        }
        for (self.extra) |name| {
            try validateFeatureName(name);
            count += 1;
            byte_len += name.len;
        }
        if (count == 0) return null;

        const result = try allocator.alloc(u8, byte_len + count - 1);
        errdefer allocator.free(result);

        var cursor: usize = 0;
        var emitted: usize = 0;
        for (known) |maybe_name| {
            if (maybe_name) |name| {
                appendFeature(result, &cursor, &emitted, name);
            }
        }
        for (self.extra) |name| {
            appendFeature(result, &cursor, &emitted, name);
        }
        std.debug.assert(cursor == result.len);
        return result;
    }

    fn validateFeatureName(name: []const u8) error{InvalidFeatureName}!void {
        if (name.len == 0) return error.InvalidFeatureName;
        if (!std.mem.eql(u8, name, std.mem.trim(u8, name, " \t\r\n"))) {
            return error.InvalidFeatureName;
        }
        if (std.mem.indexOfAny(u8, name, ",\x00") != null) {
            return error.InvalidFeatureName;
        }
    }

    fn appendFeature(
        output: []u8,
        cursor: *usize,
        emitted: *usize,
        name: []const u8,
    ) void {
        if (emitted.* != 0) {
            output[cursor.*] = ',';
            cursor.* += 1;
        }
        @memcpy(output[cursor.*..][0..name.len], name);
        cursor.* += name.len;
        emitted.* += 1;
    }
};

pub const EncryptionCipher = enum {
    aes128gcm,
    aes256gcm,
    aegis256,
    aegis128l,
    aegis128x2,
    aegis128x4,
    aegis256x2,
    aegis256x4,

    pub fn name(self: EncryptionCipher) []const u8 {
        return @tagName(self);
    }

    pub fn keyBytes(self: EncryptionCipher) usize {
        return switch (self) {
            .aes128gcm, .aegis128l, .aegis128x2, .aegis128x4 => 16,
            .aes256gcm, .aegis256, .aegis256x2, .aegis256x4 => 32,
        };
    }
};

pub const EncryptionOptions = struct {
    cipher: EncryptionCipher,
    hex_key: []const u8,

    pub const ValidationError = error{
        InvalidHexKeyLength,
        InvalidHexKey,
    };

    pub fn validate(self: EncryptionOptions) ValidationError!void {
        if (self.hex_key.len != self.cipher.keyBytes() * 2) {
            return error.InvalidHexKeyLength;
        }
        for (self.hex_key) |byte| {
            if (!std.ascii.isHex(byte)) return error.InvalidHexKey;
        }
    }
};

test "VFS names match the upstream SDK Kit tokens" {
    const memory: Vfs = .memory;
    const syscall: Vfs = .syscall;
    const io_uring: Vfs = .io_uring;
    const win_iocp: Vfs = .experimental_win_iocp;
    const automatic: Vfs = .automatic;

    try std.testing.expectEqualStrings("memory", memory.name().?);
    try std.testing.expectEqualStrings("syscall", syscall.name().?);
    try std.testing.expectEqualStrings("io_uring", io_uring.name().?);
    try std.testing.expectEqualStrings(
        "experimental_win_iocp",
        win_iocp.name().?,
    );
    try std.testing.expect(automatic.name() == null);
    try std.testing.expectEqualStrings("test-vfs", (Vfs{ .custom = "test-vfs" }).name().?);
}

test "VFS validation rejects target-invalid built-ins and empty custom names" {
    try @as(Vfs, .automatic).validateForTarget();
    try @as(Vfs, .memory).validateForTarget();
    try @as(Vfs, .syscall).validateForTarget();
    try (Vfs{ .custom = "registered-vfs" }).validateForTarget();
    try std.testing.expectError(error.InvalidVfsName, (Vfs{ .custom = "" }).validateForTarget());

    if (builtin.os.tag == .linux) {
        try @as(Vfs, .io_uring).validateForTarget();
        try std.testing.expectError(error.UnsupportedVfs, @as(Vfs, .experimental_win_iocp).validateForTarget());
    } else if (builtin.os.tag == .windows) {
        try @as(Vfs, .experimental_win_iocp).validateForTarget();
        try std.testing.expectError(error.UnsupportedVfs, @as(Vfs, .io_uring).validateForTarget());
    } else {
        try std.testing.expectError(error.UnsupportedVfs, @as(Vfs, .io_uring).validateForTarget());
        try std.testing.expectError(error.UnsupportedVfs, @as(Vfs, .experimental_win_iocp).validateForTarget());
    }
}

test "FeatureSet renders known features in stable order" {
    const allocator = std.testing.allocator;
    const rendered = (try (FeatureSet{
        .views = true,
        .encryption = true,
        .without_rowid = true,
    }).render(allocator)).?;
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "views,encryption,without_rowid",
        rendered,
    );
}

test "FeatureSet appends validated forward-compatible features" {
    const allocator = std.testing.allocator;
    const extra = [_][]const u8{ "future_one", "future_two" };
    const rendered = (try (FeatureSet{
        .attach = true,
        .extra = &extra,
    }).render(allocator)).?;
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "attach,future_one,future_two",
        rendered,
    );
}

test "FeatureSet returns null for defaults and rejects ambiguous names" {
    try std.testing.expect((try (FeatureSet{}).render(std.testing.allocator)) == null);

    const comma = [_][]const u8{"bad,name"};
    try std.testing.expectError(
        error.InvalidFeatureName,
        (FeatureSet{ .extra = &comma }).render(std.testing.allocator),
    );

    const whitespace = [_][]const u8{" bad"};
    try std.testing.expectError(
        error.InvalidFeatureName,
        (FeatureSet{ .extra = &whitespace }).render(std.testing.allocator),
    );
}

test "EncryptionOptions validates cipher-specific hex key sizes" {
    const key128 = "00112233445566778899aabbccddeeff";
    const key256 = key128 ++ key128;

    try (EncryptionOptions{
        .cipher = .aes128gcm,
        .hex_key = key128,
    }).validate();
    try (EncryptionOptions{
        .cipher = .aegis256,
        .hex_key = key256,
    }).validate();

    try std.testing.expectError(
        error.InvalidHexKeyLength,
        (EncryptionOptions{
            .cipher = .aes256gcm,
            .hex_key = key128,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHexKey,
        (EncryptionOptions{
            .cipher = .aes128gcm,
            .hex_key = "00112233445566778899aabbccddeefg",
        }).validate(),
    );
}
