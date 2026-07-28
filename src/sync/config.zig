const std = @import("std");
const builtin = @import("builtin");
const raw = @import("raw.zig").c;
const base_config = @import("../config.zig");
const cstring = @import("../cstring.zig");
const ffi = @import("../ffi.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const partial_policy = @import("partial_policy.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;

pub const PartialBootstrap = union(enum) {
    prefix_bytes: u31,
    query: []const u8,
};

/// Base database settings used by the sync engine. `async_io` is intentionally
/// not exposed: sync operation I/O is driven through the sync queue, while
/// statement I/O is handled by the adopted Connection's inline policy.
pub const LocalConfig = struct {
    path: []const u8,
    vfs: ?base_config.Vfs = null,
    features: base_config.FeatureSet = .{},
    encryption: ?base_config.EncryptionOptions = null,
};

/// Sync-engine settings supported by the pinned C ABI.
///
/// Remote cipher selection is deliberately absent because the pinned native
/// implementation ignores that header field. The optional key is accepted for
/// databases whose remote cipher is already established by the service.
pub const SyncConfig = struct {
    remote_url: ?[]const u8 = null,
    client_name: []const u8,
    long_poll_timeout_ms: u31 = 0,
    bootstrap_if_empty: bool = false,
    reserved_bytes: u31 = 0,
    partial_bootstrap: ?PartialBootstrap = null,
    partial_bootstrap_segment_size: usize = 0,
    partial_bootstrap_prefetch: bool = false,
    remote_encryption_key: ?[]const u8 = null,
    push_operations_threshold: usize = 0,
    pull_bytes_threshold: usize = 0,
    logical_mvcc_pull: bool = false,
};

pub const NativeConfig = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    remote_url: ?[:0]u8 = null,
    client_name: [:0]u8,
    features: ?[:0]u8 = null,
    vfs: ?[:0]u8 = null,
    local_cipher: ?[:0]u8 = null,
    local_key: ?[:0]u8 = null,
    partial_query: ?[:0]u8 = null,
    remote_key: ?[:0]u8 = null,
    base: raw.turso_database_config_t,
    sync: raw.turso_sync_database_config_t,

    pub fn init(
        allocator: std.mem.Allocator,
        local: LocalConfig,
        sync_config: SyncConfig,
        diagnostics: ?*Diagnostics,
    ) !NativeConfig {
        if (local.path.len == 0 or sync_config.client_name.len == 0) {
            ffi.setWrapperError(diagnostics, "sync database path and client name must not be empty");
            return error.InvalidState;
        }
        if (sync_config.partial_bootstrap == null and
            (sync_config.partial_bootstrap_segment_size != 0 or sync_config.partial_bootstrap_prefetch))
        {
            ffi.setWrapperError(diagnostics, "partial bootstrap tuning requires a prefix or query strategy");
            return error.InvalidState;
        }
        if (sync_config.partial_bootstrap) |strategy| switch (strategy) {
            .prefix_bytes => |value| if (value == 0) {
                ffi.setWrapperError(diagnostics, "partial bootstrap prefix must be greater than zero");
                return error.InvalidState;
            },
            .query => |value| if (value.len == 0) {
                ffi.setWrapperError(diagnostics, "partial bootstrap query must not be empty");
                return error.InvalidState;
            },
        };
        partial_policy.validate(
            local.path,
            sync_config.partial_bootstrap != null,
            builtin.os.tag,
        ) catch |err| {
            ffi.setWrapperError(
                diagnostics,
                "file-backed partial bootstrap requires Linux in the pinned Turso SDK Kit",
            );
            return err;
        };
        if (local.vfs) |vfs_value| {
            vfs_value.validateForTarget() catch |err| {
                ffi.setWrapperError(diagnostics, "selected local VFS is invalid or unsupported on this target");
                return err;
            };
        }
        if (local.encryption) |encryption| {
            encryption.validate() catch |err| {
                ffi.setWrapperError(diagnostics, "local encryption configuration is invalid");
                return err;
            };
        }

        var result: NativeConfig = undefined;
        result.allocator = allocator;
        result.path = try duplicate(allocator, local.path, diagnostics, "sync database path is invalid or could not be copied");
        errdefer allocator.free(result.path);
        result.client_name = try duplicate(allocator, sync_config.client_name, diagnostics, "sync client name is invalid or could not be copied");
        errdefer allocator.free(result.client_name);
        result.remote_url = null;
        result.features = null;
        result.vfs = null;
        result.local_cipher = null;
        result.local_key = null;
        result.partial_query = null;
        result.remote_key = null;

        if (sync_config.remote_url) |value| {
            result.remote_url = try duplicate(allocator, value, diagnostics, "remote URL is invalid or could not be copied");
        }
        errdefer if (result.remote_url) |value| allocator.free(value);

        var features = local.features;
        if (local.encryption != null) features.encryption = true;
        const rendered_features = features.render(allocator) catch |err| {
            ffi.setWrapperError(diagnostics, "local feature configuration is invalid or could not be rendered");
            return err;
        };
        if (rendered_features) |rendered| {
            defer allocator.free(rendered);
            result.features = try duplicate(allocator, rendered, diagnostics, "local feature configuration could not be copied");
        }
        errdefer if (result.features) |value| allocator.free(value);

        if (local.vfs) |vfs_value| if (vfs_value.name()) |name| {
            result.vfs = try duplicate(allocator, name, diagnostics, "local VFS name could not be copied");
        };
        errdefer if (result.vfs) |value| allocator.free(value);

        if (local.encryption) |encryption| {
            result.local_cipher = try duplicate(allocator, encryption.cipher.name(), diagnostics, "local encryption configuration could not be copied");
            result.local_key = duplicate(allocator, encryption.hex_key, diagnostics, "local encryption configuration could not be copied") catch |err| {
                allocator.free(result.local_cipher.?);
                result.local_cipher = null;
                return err;
            };
        }
        errdefer if (result.local_cipher) |value| allocator.free(value);
        errdefer if (result.local_key) |value| {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        };

        var prefix: i32 = 0;
        if (sync_config.partial_bootstrap) |strategy| switch (strategy) {
            .prefix_bytes => |value| prefix = @intCast(value),
            .query => |value| result.partial_query = try duplicate(
                allocator,
                value,
                diagnostics,
                "partial bootstrap query is invalid or could not be copied",
            ),
        };
        errdefer if (result.partial_query) |value| allocator.free(value);

        if (sync_config.remote_encryption_key) |value| {
            result.remote_key = try duplicate(
                allocator,
                value,
                diagnostics,
                "remote encryption configuration is invalid or could not be copied",
            );
        }
        errdefer if (result.remote_key) |value| {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        };

        result.base = .{
            .async_io = 0,
            .path = result.path.ptr,
            .experimental_features = optionalPtr(result.features),
            .vfs = optionalPtr(result.vfs),
            .encryption_cipher = optionalPtr(result.local_cipher),
            .encryption_hexkey = optionalPtr(result.local_key),
        };
        result.sync = .{
            .path = result.path.ptr,
            .remote_url = optionalPtr(result.remote_url),
            .client_name = result.client_name.ptr,
            .long_poll_timeout_ms = @intCast(sync_config.long_poll_timeout_ms),
            .bootstrap_if_empty = sync_config.bootstrap_if_empty,
            .reserved_bytes = @intCast(sync_config.reserved_bytes),
            .partial_bootstrap_strategy_prefix = prefix,
            .partial_bootstrap_strategy_query = optionalPtr(result.partial_query),
            .partial_bootstrap_segment_size = sync_config.partial_bootstrap_segment_size,
            .partial_bootstrap_prefetch = sync_config.partial_bootstrap_prefetch,
            .remote_encryption_key = optionalPtr(result.remote_key),
            .remote_encryption_cipher = null,
            .push_operations_threshold = sync_config.push_operations_threshold,
            .pull_bytes_threshold = sync_config.pull_bytes_threshold,
            .logical_mvcc_pull = sync_config.logical_mvcc_pull,
        };
        return result;
    }

    pub fn deinit(self: *NativeConfig) void {
        if (self.remote_key) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
        if (self.local_key) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
        if (self.partial_query) |value| self.allocator.free(value);
        if (self.local_cipher) |value| self.allocator.free(value);
        if (self.vfs) |value| self.allocator.free(value);
        if (self.features) |value| self.allocator.free(value);
        if (self.remote_url) |value| self.allocator.free(value);
        self.allocator.free(self.client_name);
        self.allocator.free(self.path);
    }
};

fn duplicate(
    allocator: std.mem.Allocator,
    value: []const u8,
    diagnostics: ?*Diagnostics,
    detail: []const u8,
) ![:0]u8 {
    return cstring.dupe(allocator, value) catch |err| {
        ffi.setWrapperError(diagnostics, detail);
        return err;
    };
}

fn optionalPtr(value: ?[:0]u8) [*c]u8 {
    return if (value) |bytes| bytes.ptr else null;
}
