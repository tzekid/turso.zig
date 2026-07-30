const std = @import("std");

pub fn build(b: *std.Build) void {
    const project_root = b.option(
        []const u8,
        "project-root",
        "Absolute turso.zig checkout path",
    ) orelse @panic("-Dproject-root is required");
    const native_lib_dir = b.option(
        []const u8,
        "native-lib-dir",
        "Directory containing libturso_sdk_kit.so",
    ) orelse @panic("-Dnative-lib-dir is required");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options_module = b.createModule(.{
        .root_source_file = .{
            .cwd_relative = b.pathJoin(&.{ project_root, "src/build_options.zig" }),
        },
        .target = target,
        .optimize = optimize,
    });
    const turso_module = b.createModule(.{
        .root_source_file = .{
            .cwd_relative = b.pathJoin(&.{ project_root, "src/turso.zig" }),
        },
        .target = target,
        .optimize = optimize,
    });
    const translate_c = b.addTranslateC(.{
        .root_source_file = .{
            .cwd_relative = b.pathJoin(&.{ project_root, "include/turso.h" }),
        },
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ project_root, "include" }),
    });
    turso_module.addImport("turso_c", translate_c.createModule());
    turso_module.addIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ project_root, "include" }),
    });
    turso_module.addImport("turso_build_options", build_options_module);
    turso_module.addLibraryPath(.{ .cwd_relative = native_lib_dir });
    turso_module.addRPath(.{ .cwd_relative = native_lib_dir });
    turso_module.linkSystemLibrary("turso_sdk_kit", .{
        .needed = true,
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    turso_module.link_libc = true;

    const fixture = b.addExecutable(.{
        .name = "turso-disk-fault-fixture",
        .root_module = b.createModule(.{
            .root_source_file = .{
                .cwd_relative = b.pathJoin(&.{ project_root, "tests/disk_fault.zig" }),
            },
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    fixture.root_module.link_libc = true;
    b.installArtifact(fixture);
}
