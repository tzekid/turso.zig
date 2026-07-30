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
    mvcc_passive_checkpoint: bool = false,
    /// Unverified feature names forwarded to the pinned SDK Kit parser.
    ///
    /// Upstream silently ignores unknown names. Syntactic acceptance here is
    /// therefore not a support or compatibility promise.
    unchecked_extra: []const []const u8 = &.{},

    pub const RenderError = std.mem.Allocator.Error || error{InvalidFeatureName};

    pub fn render(self: FeatureSet, allocator: std.mem.Allocator) RenderError!?[]u8 {
        const known = [_]KnownFeature{
            .{ .name = "views", .enabled = self.views },
            .{ .name = "index_method", .enabled = self.index_method },
            .{ .name = "custom_types", .enabled = self.custom_types },
            .{ .name = "autovacuum", .enabled = self.autovacuum },
            .{ .name = "vacuum", .enabled = self.vacuum },
            .{ .name = "encryption", .enabled = self.encryption },
            .{ .name = "attach", .enabled = self.attach },
            .{ .name = "generated_columns", .enabled = self.generated_columns },
            .{ .name = "multiprocess_wal", .enabled = self.multiprocess_wal },
            .{ .name = "without_rowid", .enabled = self.without_rowid },
            .{
                .name = "mvcc_passive_checkpoint",
                .enabled = self.mvcc_passive_checkpoint,
            },
        };

        var count: usize = 0;
        var byte_len: usize = 0;
        for (known) |feature| {
            if (!feature.enabled) continue;
            count = std.math.add(usize, count, 1) catch return error.OutOfMemory;
            byte_len = std.math.add(usize, byte_len, feature.name.len) catch
                return error.OutOfMemory;
        }
        for (self.unchecked_extra, 0..) |name, index| {
            try validateFeatureName(name);
            for (known) |feature| {
                if (std.mem.eql(u8, name, feature.name)) {
                    return error.InvalidFeatureName;
                }
            }
            for (self.unchecked_extra[0..index]) |earlier| {
                if (std.mem.eql(u8, name, earlier)) {
                    return error.InvalidFeatureName;
                }
            }
            count = std.math.add(usize, count, 1) catch return error.OutOfMemory;
            byte_len = std.math.add(usize, byte_len, name.len) catch
                return error.OutOfMemory;
        }
        if (count == 0) return null;

        const result_len = std.math.add(usize, byte_len, count - 1) catch
            return error.OutOfMemory;
        const result = try allocator.alloc(u8, result_len);
        errdefer allocator.free(result);

        var cursor: usize = 0;
        var emitted: usize = 0;
        for (known) |feature| {
            if (!feature.enabled) continue;
            appendFeature(result, &cursor, &emitted, feature.name);
        }
        for (self.unchecked_extra) |name| {
            appendFeature(result, &cursor, &emitted, name);
        }
        std.debug.assert(cursor == result.len);
        return result;
    }

    fn validateFeatureName(name: []const u8) error{InvalidFeatureName}!void {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) {
            return error.InvalidFeatureName;
        }
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

    const KnownFeature = struct {
        name: []const u8,
        enabled: bool,
    };
};

/// Encryption configuration requires the matching SDK Kit feature token.
/// Kept in this internal module so local and sync database construction cannot
/// drift.
pub fn requireEncryptionFeature(features: *FeatureSet, configured: bool) void {
    if (configured) features.encryption = true;
}

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

test "FeatureSet renders every promoted SDK Kit feature exactly once in stable order" {
    const allocator = std.testing.allocator;
    const rendered = (try (FeatureSet{
        .views = true,
        .index_method = true,
        .custom_types = true,
        .autovacuum = true,
        .vacuum = true,
        .encryption = true,
        .attach = true,
        .generated_columns = true,
        .multiprocess_wal = true,
        .without_rowid = true,
        .mvcc_passive_checkpoint = true,
    }).render(allocator)).?;
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "views,index_method,custom_types,autovacuum,vacuum,encryption," ++
            "attach,generated_columns,multiprocess_wal,without_rowid," ++
            "mvcc_passive_checkpoint",
        rendered,
    );
}

test "FeatureSet appends syntactically valid unchecked names in caller order" {
    const allocator = std.testing.allocator;
    const unchecked = [_][]const u8{ "future_two", "future_one" };
    const rendered = (try (FeatureSet{
        .attach = true,
        .unchecked_extra = &unchecked,
    }).render(allocator)).?;
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "attach,future_two,future_one",
        rendered,
    );
}

test "FeatureSet returns null for defaults and rejects invalid unchecked names" {
    try std.testing.expect((try (FeatureSet{}).render(std.testing.allocator)) == null);

    const invalid = [_][]const []const u8{
        &.{""},
        &.{"bad,name"},
        &.{"bad\x00name"},
        &.{" bad"},
        &.{"bad "},
        &.{&.{0xff}},
    };
    for (invalid) |names| {
        try std.testing.expectError(
            error.InvalidFeatureName,
            (FeatureSet{ .unchecked_extra = names }).render(std.testing.allocator),
        );
    }
}

test "FeatureSet rejects duplicate and typed unchecked names" {
    const duplicate = [_][]const u8{ "future", "future" };
    try std.testing.expectError(
        error.InvalidFeatureName,
        (FeatureSet{ .unchecked_extra = &duplicate }).render(std.testing.allocator),
    );

    const known = [_][]const u8{"views"};
    try std.testing.expectError(
        error.InvalidFeatureName,
        (FeatureSet{ .unchecked_extra = &known }).render(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidFeatureName,
        (FeatureSet{
            .views = true,
            .unchecked_extra = &known,
        }).render(std.testing.allocator),
    );
}

test "FeatureSet rendering reports allocation failure without partial ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        (FeatureSet{ .views = true }).render(failing.allocator()),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "encryption configuration enables its required feature without clearing others" {
    var features = FeatureSet{ .views = true };
    requireEncryptionFeature(&features, true);
    const rendered = (try features.render(std.testing.allocator)).?;
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("views,encryption", rendered);

    requireEncryptionFeature(&features, false);
    try std.testing.expect(features.encryption);
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
