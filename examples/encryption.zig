const std = @import("std");
const turso = @import("turso");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();

    const key_path = arguments.next() orelse {
        std.debug.print("usage: turso-encryption <path-to-64-character-AES-256-hex-key-file>\n", .{});
        return error.MissingEncryptionKey;
    };
    if (arguments.next() != null) {
        std.debug.print("usage: turso-encryption <path-to-64-character-AES-256-hex-key-file>\n", .{});
        return error.UnexpectedArgument;
    }

    // The command line carries only a path, never the key. Production
    // applications should replace this file read with a secret-manager API.
    // Restrict the file's permissions and delete it according to local policy.
    const key_storage = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        key_path,
        init.gpa,
        .limited(66),
    );
    defer {
        std.crypto.secureZero(u8, key_storage);
        init.gpa.free(key_storage);
    }
    var key_len = key_storage.len;
    while (key_len != 0 and (key_storage[key_len - 1] == '\n' or key_storage[key_len - 1] == '\r')) {
        key_len -= 1;
    }
    const mutable_key = key_storage[0..key_len];

    var random_bytes: [12]u8 = undefined;
    init.io.random(&random_bytes);
    const random_name = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(init.gpa, ".turso-zig-encryption-{s}", .{random_name});
    defer init.gpa.free(temp_name);

    const cwd = std.Io.Dir.cwd();
    var temp_dir = try cwd.createDirPathOpen(init.io, temp_name, .{});
    defer {
        temp_dir.close(init.io);
        cwd.deleteTree(init.io, temp_name) catch |err| {
            // The path is not secret; the key is never logged.
            std.debug.print("warning: could not remove temporary encryption example directory: {s}\n", .{@errorName(err)});
        };
    }

    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try temp_dir.realPath(init.io, &absolute_buffer);
    const database_path = try std.fmt.allocPrint(init.gpa, "{s}/encrypted.db", .{absolute_buffer[0..absolute_len]});
    defer init.gpa.free(database_path);

    try runEncryptedRoundTrip(init.gpa, database_path, mutable_key);
    std.debug.print("encrypted database reopened successfully; temporary files removed on exit\n", .{});
}

/// Takes ownership of the secret bytes for the duration of this operation and
/// wipes them before returning, including on validation/open/query failure.
fn runEncryptedRoundTrip(
    allocator: std.mem.Allocator,
    database_path: []const u8,
    mutable_hex_key: []u8,
) !void {
    // Volatile secure zeroing prevents this wipe from being optimized away.
    defer std.crypto.secureZero(u8, mutable_hex_key);

    const encryption = turso.EncryptionOptions{
        .cipher = .aes256gcm,
        .hex_key = mutable_hex_key,
    };
    try encryption.validate();

    {
        var database = try turso.Database.open(allocator, .{
            .path = database_path,
            .encryption = encryption,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();

        _ = try connection.exec("CREATE TABLE secrets(value TEXT NOT NULL)", &.{}, .{});
        _ = try connection.exec(
            "INSERT INTO secrets(value) VALUES (?1)",
            &.{.{ .text = "encrypted at rest" }},
            .{},
        );
    }

    // Reopen using the same still-live key to prove that data is readable only
    // after a fresh encrypted Database.open lifecycle.
    {
        var database = try turso.Database.open(allocator, .{
            .path = database_path,
            .encryption = encryption,
        });
        defer database.deinit();
        var connection = try database.connect(.{});
        defer connection.deinit();

        var rows = try connection.query("SELECT value FROM secrets", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.ExpectedEncryptedRow;
        if (!std.mem.eql(u8, "encrypted at rest", try row.get([]const u8, 0))) {
            return error.UnexpectedEncryptedValue;
        }
    }
}
