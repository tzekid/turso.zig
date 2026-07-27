const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const zig_exe = args.next() orelse return usage();
    const input_path = args.next() orelse return usage();
    const output_path = args.next() orelse return usage();
    var redaction_paths: std.ArrayList([]const u8) = .empty;
    defer redaction_paths.deinit(init.gpa);
    while (args.next()) |path| {
        if (path.len == 0) return usage();
        try redaction_paths.append(init.gpa, path);
    }

    const list_result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ zig_exe, "ar", "t", input_path },
    });
    defer init.gpa.free(list_result.stdout);
    defer init.gpa.free(list_result.stderr);
    try requireSuccess("list input archive", list_result);

    var delete_args: std.ArrayList([]const u8) = .empty;
    defer delete_args.deinit(init.gpa);
    try delete_args.appendSlice(init.gpa, &.{ zig_exe, "ar", "d", output_path });

    var lines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const member = std.mem.trim(u8, raw_line, "\r");
        if (isCompilerBuiltinsMember(member)) {
            try delete_args.append(init.gpa, member);
        }
    }
    if (delete_args.items.len == 4) return error.CompilerBuiltinsArchiveMembersMissing;

    try std.Io.Dir.cwd().copyFile(
        input_path,
        std.Io.Dir.cwd(),
        output_path,
        init.io,
        .{ .replace = true },
    );

    const delete_result = try std.process.run(init.gpa, init.io, .{
        .argv = delete_args.items,
    });
    defer init.gpa.free(delete_result.stdout);
    defer init.gpa.free(delete_result.stderr);
    try requireSuccess("remove Rust compiler builtins", delete_result);

    try redactArchivePaths(init, output_path, redaction_paths.items);

    const verify_result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ zig_exe, "ar", "t", output_path },
    });
    defer init.gpa.free(verify_result.stdout);
    defer init.gpa.free(verify_result.stderr);
    try requireSuccess("verify output archive", verify_result);

    var verify_lines = std.mem.splitScalar(u8, verify_result.stdout, '\n');
    while (verify_lines.next()) |raw_line| {
        if (isCompilerBuiltinsMember(std.mem.trim(u8, raw_line, "\r"))) {
            return error.CompilerBuiltinsArchiveMemberRemains;
        }
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: sanitize_static_archive <zig-exe> <input-archive> <output-archive> [build-path ...]\n",
        .{},
    );
    return error.InvalidArguments;
}

fn redactArchivePaths(
    init: std.process.Init,
    output_path: []const u8,
    paths: []const []const u8,
) !void {
    const archive = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        output_path,
        init.gpa,
        .limited(2 * 1024 * 1024 * 1024),
    );
    defer init.gpa.free(archive);

    for (paths) |path| {
        _ = redactAll(archive, path);

        const alternate = try init.gpa.dupe(u8, path);
        defer init.gpa.free(alternate);
        for (alternate) |*byte| {
            byte.* = switch (byte.*) {
                '/' => '\\',
                '\\' => '/',
                else => byte.*,
            };
        }
        if (!std.mem.eql(u8, path, alternate)) {
            _ = redactAll(archive, alternate);
        }
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = archive,
    });
}

fn redactAll(bytes: []u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, offset, needle)) |index| {
        @memset(bytes[index..][0..needle.len], '_');
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

fn requireSuccess(operation: []const u8, result: std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print(
        "sanitize_static_archive: unable to {s}\n{s}",
        .{ operation, result.stderr },
    );
    return error.ArchiverFailed;
}

fn isCompilerBuiltinsMember(member: []const u8) bool {
    return std.mem.indexOf(u8, member, "compiler_builtins") != null or
        std.mem.indexOf(u8, member, "compiler-builtins") != null;
}

test "recognizes Rust compiler-builtins archive members" {
    try std.testing.expect(isCompilerBuiltinsMember(
        "compiler_builtins-abc.compiler_builtins.hash-cgu.042.rcgu.o",
    ));
    try std.testing.expect(isCompilerBuiltinsMember(
        "compiler-builtins-abc.compiler-builtins.hash-cgu.0.obj",
    ));
}

test "does not remove SDK Kit or standard-library members" {
    try std.testing.expect(!isCompilerBuiltinsMember(
        "turso_sdk_kit-abc.turso_sdk_kit.hash-cgu.0.rcgu.o",
    ));
    try std.testing.expect(!isCompilerBuiltinsMember(
        "std-abc.std.hash-cgu.0.rcgu.o",
    ));
}

test "redacts build roots without changing archive size" {
    var contents = "before D:\\work\\cache\\native.o and /home/me/.cargo/member.o after".*;
    const original_length = contents.len;

    try std.testing.expectEqual(@as(usize, 1), redactAll(&contents, "D:\\work\\cache"));
    try std.testing.expectEqual(@as(usize, 1), redactAll(&contents, "/home/me/.cargo"));
    try std.testing.expectEqual(original_length, contents.len);
    try std.testing.expect(std.mem.indexOf(u8, &contents, "D:\\work\\cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, &contents, "/home/me/.cargo") == null);
}
