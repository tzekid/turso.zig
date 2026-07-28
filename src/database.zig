const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const config_mod = @import("config.zig");
const cstring = @import("cstring.zig");
const ffi = @import("ffi.zig");
const connection_mod = @import("connection.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Vfs = config_mod.Vfs;
pub const FeatureSet = config_mod.FeatureSet;
pub const EncryptionOptions = config_mod.EncryptionOptions;
pub const Connection = connection_mod.Connection;
pub const ConnectionOptions = connection_mod.ConnectionOptions;
pub const Value = value_mod.Value;
pub const Text = value_mod.Text;
pub const Blob = value_mod.Blob;

pub const OpenError = status_mod.Error || error{
    InvalidFeatureName,
    InvalidHexKeyLength,
    InvalidHexKey,
    UnsupportedVfs,
    InvalidVfsName,
};

pub const DatabaseOptions = struct {
    path: []const u8,
    vfs: ?Vfs = null,
    features: FeatureSet = .{},
    encryption: ?EncryptionOptions = null,
    diagnostics: ?*Diagnostics = null,
};

/// Move-only owner of a native database. Every connection created from it must
/// be deinited before this value. The database may create connections from
/// multiple threads, matching the upstream contract. Because connection and
/// callback state is allocated through the allocator supplied to `open`, that
/// allocator must be thread-safe for the full owner lifetime whenever this
/// Database or any derived Connections may be used concurrently. This covers
/// every wrapper allocation and deallocation, not only `connect` and callbacks.
pub const Database = struct {
    state: ?*State,

    const State = struct {
        allocator: std.mem.Allocator,
        handle: *const raw.turso_database_t,
        active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };

    pub fn open(allocator: std.mem.Allocator, options: DatabaseOptions) OpenError!Database {
        try runtime.verifyRuntimeVersion(options.diagnostics);
        if (options.vfs) |vfs| {
            vfs.validateForTarget() catch |err| {
                ffi.setWrapperError(options.diagnostics, switch (err) {
                    error.UnsupportedVfs => "selected VFS is not supported on this target",
                    error.InvalidVfsName => "custom VFS name must not be empty",
                });
                return err;
            };
        }
        const path = cstring.dupe(allocator, options.path) catch |err| {
            ffi.setWrapperError(options.diagnostics, "database path is not valid UTF-8, contains an interior NUL, or could not be copied");
            return err;
        };
        defer allocator.free(path);

        var features = options.features;
        config_mod.requireEncryptionFeature(&features, options.encryption != null);
        const feature_bytes = features.render(allocator) catch |err| {
            ffi.setWrapperError(
                options.diagnostics,
                if (err == error.OutOfMemory)
                    "experimental feature list could not be allocated"
                else
                    "unchecked feature names must be unique valid UTF-8 tokens and must not duplicate typed features",
            );
            return err;
        };
        defer if (feature_bytes) |bytes| allocator.free(bytes);
        const feature_string = if (feature_bytes) |bytes|
            cstring.dupe(allocator, bytes) catch |err| {
                ffi.setWrapperError(options.diagnostics, "experimental feature list is not valid UTF-8 or could not be copied");
                return err;
            }
        else
            null;
        defer if (feature_string) |value| allocator.free(value);

        const vfs_string = if (options.vfs) |vfs| if (vfs.name()) |name|
            cstring.dupe(allocator, name) catch |err| {
                ffi.setWrapperError(options.diagnostics, "VFS name is not valid UTF-8, contains an interior NUL, or could not be copied");
                return err;
            }
        else
            null else null;
        defer if (vfs_string) |value| allocator.free(value);

        var cipher_string: ?[:0]u8 = null;
        var key_string: ?[:0]u8 = null;
        if (options.encryption) |encryption| {
            encryption.validate() catch |err| {
                ffi.setWrapperError(options.diagnostics, "invalid encryption key format or length");
                return err;
            };
            cipher_string = cstring.dupe(allocator, encryption.cipher.name()) catch |err| {
                ffi.setWrapperError(options.diagnostics, "encryption cipher could not be copied");
                return err;
            };
            key_string = cstring.dupe(allocator, encryption.hex_key) catch |err| {
                allocator.free(cipher_string.?);
                cipher_string = null;
                ffi.setWrapperError(options.diagnostics, "encryption key could not be copied");
                return err;
            };
        }
        defer if (cipher_string) |value| allocator.free(value);
        defer if (key_string) |value| {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        };

        const native_config = raw.turso_database_config_t{
            .async_io = 0,
            .path = path.ptr,
            .experimental_features = if (feature_string) |value| value.ptr else null,
            .vfs = if (vfs_string) |value| value.ptr else null,
            .encryption_cipher = if (cipher_string) |value| value.ptr else null,
            .encryption_hexkey = if (key_string) |value| value.ptr else null,
        };

        var handle: ?*const raw.turso_database_t = null;
        var native_error: ffi.NativeError = null;
        const create_status = raw.turso_database_new(&native_config, &handle, &native_error);
        ffi.expect(create_status, native_error, .ok, options.diagnostics, "database constructor returned an unexpected control status") catch |err| {
            if (handle) |value| raw.turso_database_deinit(value);
            return err;
        };
        if (handle == null) {
            ffi.setWrapperError(options.diagnostics, "database constructor returned a null handle");
            return error.InvalidState;
        }
        errdefer raw.turso_database_deinit(handle.?);

        native_error = null;
        const open_status = raw.turso_database_open(handle.?, &native_error);
        try ffi.expect(
            open_status,
            native_error,
            .ok,
            options.diagnostics,
            "blocking database open returned an unexpected control status",
        );

        const state = try allocator.create(State);
        state.* = .{
            .allocator = allocator,
            .handle = handle.?,
        };
        return .{ .state = state };
    }

    pub fn connect(self: *Database, options: ConnectionOptions) status_mod.Error!Connection {
        const state = self.state orelse {
            ffi.setWrapperError(options.diagnostics, "database is already deinited");
            return error.InvalidState;
        };
        if (options.busy_timeout_ms) |timeout| {
            if (timeout > std.math.maxInt(i64)) {
                ffi.setWrapperError(options.diagnostics, "busy timeout does not fit the native signed millisecond range");
                return error.IntegerOverflow;
            }
        }

        var handle: ?*raw.turso_connection_t = null;
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_database_connect(state.handle, &handle, &native_error);
        ffi.expect(native_status, native_error, .ok, options.diagnostics, "database connect returned an unexpected control status") catch |err| {
            if (handle) |value| raw.turso_connection_deinit(value);
            return err;
        };
        if (handle == null) {
            ffi.setWrapperError(options.diagnostics, "database connect returned a null handle");
            return error.InvalidState;
        }

        if (options.busy_timeout_ms) |timeout| {
            raw.turso_connection_set_busy_timeout_ms(handle.?, @intCast(timeout));
        }
        const connection = connection_mod.init(
            state.allocator,
            handle.?,
            &state.active_connections,
        ) catch |err| {
            raw.turso_connection_deinit(handle.?);
            return err;
        };
        _ = state.active_connections.fetchAdd(1, .monotonic);
        return connection;
    }

    pub fn deinit(self: *Database) void {
        const state = self.state orelse return;
        if (state.active_connections.load(.acquire) != 0) {
            @panic("turso.Database.deinit called before all connections were deinited");
        }
        raw.turso_database_deinit(state.handle);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.state = null;
    }
};
