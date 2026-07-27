const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option([]const u8, "native", "Forwarded turso native mode") orelse "source";
    const linkage = b.option([]const u8, "linkage", "Forwarded turso linkage mode") orelse "static";
    const native_path = b.option([]const u8, "native-path", "Forwarded turso native prefix");
    const sync = b.option(bool, "sync", "Import and compile the opt-in turso_sync module") orelse false;
    const allow_source_cross = b.option(
        bool,
        "allow-source-cross",
        "Forward source-mode cross-toolchain acknowledgement",
    ) orelse false;
    const turso = if (native_path) |path|
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = native,
            .linkage = linkage,
            .@"native-path" = path,
            .sync = sync,
            .@"allow-source-cross" = allow_source_cross,
        })
    else
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = native,
            .linkage = linkage,
            .sync = sync,
            .@"allow-source-cross" = allow_source_cross,
        });

    const executable = b.addExecutable(.{
        .name = "turso-consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path(if (sync) "src/sync.zig" else "src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = if (sync)
                &.{.{ .name = "turso_sync", .module = turso.module("turso_sync") }}
            else
                &.{.{ .name = "turso", .module = turso.module("turso") }},
        }),
    });

    const run = b.addRunArtifact(executable);
    const run_step = b.step("run", "Build and run the clean consumer smoke test");
    run_step.dependOn(&run.step);
}
