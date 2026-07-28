//! Zig 0.16 blocking standard-library transport.
//!
//! The adapter borrows a caller-owned `std.http.Client`, allocator, `std.Io`,
//! and filesystem root. It owns no global state and never formats request
//! headers, authorization values, response bodies, or file paths into errors.

const std = @import("std");
const transport_mod = @import("transport.zig");

/// Blocking HTTP and filesystem adapter for the sync operation driver.
///
/// File requests accept only normalized, non-empty, root-relative paths. Path
/// components are separated by `/`; absolute paths, empty or dot components,
/// backslashes, and Windows drive prefixes are rejected before filesystem I/O.
///
/// This is a lexical boundary, not portable symlink confinement. The caller
/// must trust `root_dir` and its directory tree: a pre-existing symlink in a
/// path component may cause the operating system to resolve outside that root.
pub const StandardTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    /// Borrowed root for every full-file request. The caller must prevent
    /// untrusted mutation of this directory tree, including symlink changes.
    root_dir: std.Io.Dir,
    allow_http: bool = false,

    pub fn request(
        self: *StandardTransport,
        request_data: transport_mod.HttpRequest,
        response_writer: *transport_mod.ResponseWriter,
    ) !void {
        const method = parseMethod(request_data.method) orelse return error.UnsupportedHttpMethod;
        if (!method.requestHasBody() and request_data.body.len != 0) {
            return error.UnsupportedHttpBody;
        }

        const full_url = try joinUrl(self.allocator, request_data.url, request_data.path);
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);
        if (!self.allow_http and std.mem.eql(u8, uri.scheme, "http")) {
            return error.InsecureHttpDisabled;
        }
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
            return error.UnsupportedUriScheme;
        }

        if (request_data.authorization) |authorization| {
            try validateHeader(authorization);
        }
        var native_header_count = request_data.headers.len;
        for (request_data.headers) |header| {
            try validateHeader(header);
            if (request_data.authorization != null and
                std.ascii.eqlIgnoreCase(header.name, "authorization"))
            {
                native_header_count -= 1;
            }
        }

        const authorization_count: usize = if (request_data.authorization == null) 0 else 1;
        const headers = try self.allocator.alloc(
            std.http.Header,
            native_header_count + authorization_count,
        );
        defer self.allocator.free(headers);

        var destination_index: usize = 0;
        for (request_data.headers) |source| {
            if (request_data.authorization != null and
                std.ascii.eqlIgnoreCase(source.name, "authorization"))
            {
                continue;
            }
            headers[destination_index] = .{ .name = source.name, .value = source.value };
            destination_index += 1;
        }
        if (request_data.authorization) |source| {
            headers[destination_index] = .{ .name = source.name, .value = source.value };
        }

        var client_request = try self.client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = headers,
            // Authorization is safe in this list because redirects are
            // deliberately unhandled and therefore never cross origins.
        });
        defer client_request.deinit();

        if (method.requestHasBody()) {
            client_request.transfer_encoding = .{ .content_length = request_data.body.len };
            var body = try client_request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(request_data.body);
            try body.end();
            try client_request.connection.?.flush();
        } else {
            try client_request.sendBodiless();
        }

        var response = try client_request.receiveHead(&.{});
        try response_writer.setStatus(@intFromEnum(response.head.status));

        var body = response.reader(&.{});
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = body.readSliceShort(&buffer) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr() orelse err,
            };
            if (count != 0) try response_writer.push(buffer[0..count]);
            if (count != buffer.len) break;
        }
    }

    /// Missing files are successful empty responses, as required by the sync
    /// C ABI. Existing files are streamed without retaining their contents.
    pub fn readFile(
        self: *StandardTransport,
        path: []const u8,
        writer: *transport_mod.BufferWriter,
    ) !void {
        try validateFilePath(path);
        var file = self.root_dir.openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |other| return other,
        };
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = try reader.interface.readSliceShort(&buffer);
            if (count != 0) try writer.push(buffer[0..count]);
            if (count != buffer.len) break;
        }
    }

    /// Write, synchronize, and atomically replace `path` with a same-directory
    /// unique temporary file. `deinit` removes the temporary on every failure.
    pub fn writeFileAtomically(
        self: *StandardTransport,
        path: []const u8,
        content: []const u8,
    ) !void {
        try validateFilePath(path);
        var atomic = try self.root_dir.createFileAtomic(self.io, path, .{ .replace = true });
        defer atomic.deinit(self.io);

        try atomic.file.writeStreamingAll(self.io, content);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};

fn validateFilePath(path: []const u8) !void {
    if (path.len == 0 or
        path[0] == '/' or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, 0) != null or
        hasWindowsDrivePrefix(path))
    {
        return error.InvalidFilePath;
    }

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidFilePath;
        }
    }
}

fn hasWindowsDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':';
}

fn parseMethod(method: []const u8) ?std.http.Method {
    inline for (std.meta.tags(std.http.Method)) |candidate| {
        if (std.mem.eql(u8, method, @tagName(candidate))) return candidate;
    }
    return null;
}

fn validateHeader(header: transport_mod.HttpHeader) !void {
    if (header.name.len == 0) return error.InvalidHttpHeader;
    for (header.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
        {
            return error.InvalidHttpHeader;
        }
    }
    if (std.mem.indexOfAny(u8, header.value, "\r\n") != null) {
        return error.InvalidHttpHeader;
    }
}

fn joinUrl(
    allocator: std.mem.Allocator,
    base: []const u8,
    path: []const u8,
) ![]u8 {
    if (base.len == 0) return allocator.dupe(u8, path);
    if (path.len == 0) return allocator.dupe(u8, base);

    const base_slash = base[base.len - 1] == '/';
    const path_slash = path[0] == '/';
    if (base_slash and path_slash) {
        return std.mem.concat(allocator, u8, &.{ base, path[1..] });
    }
    if (!base_slash and !path_slash) {
        return std.mem.concat(allocator, u8, &.{ base, "/", path });
    }
    return std.mem.concat(allocator, u8, &.{ base, path });
}

test "method parsing and URL joining are deterministic" {
    try std.testing.expectEqual(std.http.Method.POST, parseMethod("POST").?);
    try std.testing.expect(parseMethod("post") == null);

    const joined = try joinUrl(std.testing.allocator, "https://example.invalid/", "/sync");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("https://example.invalid/sync", joined);
}

test "header validation accepts RFC token names and rejects invalid bytes" {
    try validateHeader(.{
        .name = "x-!#$%&'*+.^_`|~",
        .value = "visible value\twith tab",
    });

    const invalid_names = [_][]const u8{
        "",
        "bad name",
        "bad:name",
        "bad\tname",
        "bad\rname",
        "bad\nname",
        "bad\x00name",
        "bad\x80name",
    };
    for (invalid_names) |name| {
        try std.testing.expectError(
            error.InvalidHttpHeader,
            validateHeader(.{ .name = name, .value = "value" }),
        );
    }
    try std.testing.expectError(
        error.InvalidHttpHeader,
        validateHeader(.{ .name = "x-valid", .value = "line\r\ninjection" }),
    );
}
