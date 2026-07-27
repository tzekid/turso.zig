const std = @import("std");
const sync = @import("turso_sync");

pub fn main(init: std.process.Init) !void {
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    // Compile the public sync owner and the caller-owned standard transport
    // without constructing a database or initiating credentialed network I/O.
    var transport = sync.StandardTransport{
        .allocator = init.gpa,
        .io = init.io,
        .client = &client,
        .root_dir = .cwd(),
    };
    _ = &transport;
    _ = @sizeOf(sync.SyncDatabase);
    _ = @sizeOf(sync.Operation(void));
}
