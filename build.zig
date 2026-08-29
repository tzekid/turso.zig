const std = @import("std");
const builtin = @import("builtin");
const package_version = @import("src/version.zig");
const invariant = @import("src/invariant.zig");

const NativeMode = enum { source, system };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_mode = b.option(NativeMode, "native", "Native backend: source (default) or system") orelse .source;
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Turso native linkage: static (default) or dynamic") orelse .static;
    const native_path = b.option([]const u8, "native-path", "System-mode prefix containing lib/ (and optionally include/)");
    const turso_source = b.option([]const u8, "turso-source", "Existing Turso source checkout used instead of the pinned package");
    const rust_target_override = b.option([]const u8, "rust-target", "Override the Rust target triple used by source mode");
    const allow_source_cross = b.option(bool, "allow-source-cross", "Allow externally configured Cargo cross-linking (advanced, unverified)") orelse false;
    const encryption = b.option(bool, "encryption", "Build Turso encryption support") orelse true;
    const fts = b.option(bool, "fts", "Build Turso full-text-search support") orelse false;
    const sync = b.option(bool, "sync", "Build and link the opt-in Turso Cloud sync SDK Kit") orelse false;
    const expected_runtime_version = if (turso_source) |path|
        readWorkspaceVersion(b, path)
    else
        package_version.upstream;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "expected_runtime_version", expected_runtime_version);
    const build_options_module = build_options.createModule();
    const pinned_build_options = b.addOptions();
    pinned_build_options.addOption([]const u8, "expected_runtime_version", package_version.upstream);
    const pinned_build_options_module = pinned_build_options.createModule();
    const native_artifact_step = b.step(
        "native-artifact",
        "Build and install the selected source-mode SDK Kit artifact",
    );
    const base_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/turso.h"),
        .target = target,
        .optimize = optimize,
    });
    base_translate_c.addIncludePath(b.path("include"));
    const base_c_module = base_translate_c.createModule();
    const sync_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/turso_sync.h"),
        .target = target,
        .optimize = optimize,
    });
    sync_translate_c.addIncludePath(b.path("include"));
    const sync_c_module = sync_translate_c.createModule();

    const native = configureNative(b, .{
        .mode = native_mode,
        .linkage = linkage,
        .target = target,
        .optimize = optimize,
        .native_path = native_path,
        .turso_source = turso_source,
        .rust_target_override = rust_target_override,
        .allow_source_cross = allow_source_cross,
        .encryption = encryption,
        .fts = fts,
        .sync = sync,
        .native_artifact_step = native_artifact_step,
    });

    const abi_symbols_command = b.addSystemCommand(&.{ "bash", absolutePath(b, "tools/check-abi-symbols.sh") });
    if (sync) abi_symbols_command.addArg("--sync");
    switch (native) {
        .exact_file => |exact| abi_symbols_command.addFileArg(exact.file),
        .search => {
            if (native_path) |prefix| {
                abi_symbols_command.addArg(b.pathJoin(&.{
                    prefix,
                    "lib",
                    nativeLibraryFilename(target.result, linkage, sync),
                }));
            } else {
                abi_symbols_command.addArg("--header-only");
            }
        },
    }
    const abi_symbols_step = b.step("test-abi-symbols", "Check the exact selected SDK Kit symbol manifest");
    abi_symbols_step.dependOn(&abi_symbols_command.step);
    const disk_fault_command = b.addSystemCommand(&.{ "bash", absolutePath(b, "tools/check-disk-fault.sh") });
    disk_fault_command.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    const disk_fault_step = b.step("test-disk-fault", "Run isolated Linux ENOSPC and short-write fault injection");
    disk_fault_step.dependOn(&disk_fault_command.step);
    const compile_32_command = b.addSystemCommand(&.{ "bash", absolutePath(b, "tools/check-32bit-compile.sh") });
    compile_32_command.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    const compile_32_step = b.step("test-32bit-compile", "Compile native-facing safety paths for a 32-bit usize target");
    compile_32_step.dependOn(&compile_32_command.step);

    const raw_module = b.addModule("turso_raw", .{
        .root_source_file = b.path("src/raw.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, raw_module, native, target.result, linkage, sync, build_options_module, base_c_module, sync_c_module);

    const turso_module = b.addModule("turso", .{
        .root_source_file = b.path("src/turso.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, turso_module, native, target.result, linkage, sync, build_options_module, base_c_module, sync_c_module);

    const sync_module = if (sync) blk: {
        const module = b.addModule("turso_sync", .{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureModule(b, module, native, target.result, linkage, true, build_options_module, base_c_module, sync_c_module);
        break :blk module;
    } else null;

    const install_header = b.addInstallHeaderFile(b.path("include/turso.h"), "turso.h");
    b.getInstallStep().dependOn(&install_header.step);
    if (sync) {
        const install_sync_header = b.addInstallHeaderFile(b.path("include/turso_sync.h"), "turso_sync.h");
        b.getInstallStep().dependOn(&install_sync_header.step);
    }

    const docs_step = b.step("docs", "Generate API documentation under zig-out/docs");
    const docs_turso_module = b.createModule(.{
        .root_source_file = b.path("src/turso.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_turso_module.addIncludePath(b.path("include"));
    docs_turso_module.addImport("turso_build_options", build_options_module);
    addCImports(docs_turso_module, base_c_module, sync_c_module, false);
    docs_turso_module.link_libc = true;
    const docs_turso = b.addObject(.{
        .name = "turso-docs",
        .root_module = docs_turso_module,
    });
    const install_turso_docs = b.addInstallDirectory(.{
        .source_dir = docs_turso.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/turso",
    });
    docs_step.dependOn(&install_turso_docs.step);

    const docs_sync_module = b.createModule(.{
        .root_source_file = b.path("src/sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_sync_module.addIncludePath(b.path("include"));
    docs_sync_module.addImport("turso_build_options", build_options_module);
    addCImports(docs_sync_module, base_c_module, sync_c_module, true);
    docs_sync_module.link_libc = true;
    const docs_sync = b.addObject(.{
        .name = "turso-sync-docs",
        .root_module = docs_sync_module,
    });
    const install_sync_docs = b.addInstallDirectory(.{
        .source_dir = docs_sync.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/turso-sync",
    });
    docs_step.dependOn(&install_sync_docs.step);

    const basic_example = b.addExecutable(.{
        .name = "turso-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_basic_example = b.addRunArtifact(basic_example);
    const basic_example_step = b.step("example-basic", "Build and run the basic in-memory CRUD example");
    basic_example_step.dependOn(&run_basic_example.step);

    const file_example = b.addExecutable(.{
        .name = "turso-file",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/file.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_file_example = b.addRunArtifact(file_example);
    const file_example_step = b.step("example-file", "Build and run the persistent file database example");
    file_example_step.dependOn(&run_file_example.step);

    const values_example = b.addExecutable(.{
        .name = "turso-values",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/values.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_values_example = b.addRunArtifact(values_example);
    const values_example_step = b.step("example-values", "Build and run the SQL value and owned-copy example");
    values_example_step.dependOn(&run_values_example.step);

    const diagnostics_example = b.addExecutable(.{
        .name = "turso-diagnostics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/diagnostics.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_diagnostics_example = b.addRunArtifact(diagnostics_example);
    const diagnostics_example_step = b.step("example-diagnostics", "Build and run the diagnostics and metadata example");
    diagnostics_example_step.dependOn(&run_diagnostics_example.step);

    const prepared_example = b.addExecutable(.{
        .name = "turso-prepared",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/prepared.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_prepared_example = b.addRunArtifact(prepared_example);
    const prepared_example_step = b.step("example-prepared", "Build and run the prepared statement reuse example");
    prepared_example_step.dependOn(&run_prepared_example.step);

    const batch_example = b.addExecutable(.{
        .name = "turso-batch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/batch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_batch_example = b.addRunArtifact(batch_example);
    const batch_example_step = b.step("example-batch", "Build and run the structured batch example");
    batch_example_step.dependOn(&run_batch_example.step);

    const transaction_example = b.addExecutable(.{
        .name = "turso-transaction",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/transaction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_transaction_example = b.addRunArtifact(transaction_example);
    const transaction_example_step = b.step("example-transaction", "Build and run the transaction lifecycle example");
    transaction_example_step.dependOn(&run_transaction_example.step);

    const functions_example = b.addExecutable(.{
        .name = "turso-functions",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/functions.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_functions_example = b.addRunArtifact(functions_example);
    const functions_example_step = b.step("example-functions", "Build and run the managed functions and collation example");
    functions_example_step.dependOn(&run_functions_example.step);

    const encryption_example = b.addExecutable(.{
        .name = "turso-encryption",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/encryption.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const install_encryption_example = b.addInstallArtifact(encryption_example, .{});
    const encryption_example_step = b.step("example-encryption", "Compile the encryption example without placing a secret in build arguments");
    encryption_example_step.dependOn(&install_encryption_example.step);

    const ergonomic_example = b.addExecutable(.{
        .name = "turso-ergonomic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ergonomic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_ergonomic_example = b.addRunArtifact(ergonomic_example);
    const ergonomic_example_step = b.step("example-ergonomic", "Run named binding, typed row, and extension-control example");
    ergonomic_example_step.dependOn(&run_ergonomic_example.step);

    const sync_example_step = b.step("example-sync", "Compile the opt-in caller-owned sync transport example");
    if (sync_module) |module| {
        const sync_example = b.addExecutable(.{
            .name = "turso-sync",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/sync.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "turso_sync", .module = module }},
            }),
        });
        const install_sync_example = b.addInstallArtifact(sync_example, .{});
        sync_example_step.dependOn(&install_sync_example.step);
    } else {
        const disabled = b.addFail("example-sync requires -Dsync=true");
        sync_example_step.dependOn(&disabled.step);
    }

    const sync_e2e_step = b.step(
        "test-sync-e2e",
        "Run local push/bootstrap/pull/apply against a tursodb sync server",
    );
    if (sync_module) |module| {
        if (b.option([]const u8, "sync-server", "Path to a tursodb binary for the local sync E2E test")) |server| {
            const sync_e2e = b.addExecutable(.{
                .name = "turso-sync-e2e",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/sync_e2e.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "turso_sync", .module = module }},
                }),
            });
            const sync_e2e_command = b.addSystemCommand(&.{
                "bash",
                absolutePath(b, "tools/check-sync-e2e.sh"),
            });
            sync_e2e_command.addArtifactArg(sync_e2e);
            sync_e2e_command.addArg(server);
            sync_e2e_step.dependOn(&sync_e2e_command.step);
        } else {
            const disabled = b.addFail("test-sync-e2e requires -Dsync=true -Dsync-server=/path/to/tursodb");
            sync_e2e_step.dependOn(&disabled.step);
        }
    } else {
        const disabled = b.addFail("test-sync-e2e requires -Dsync=true -Dsync-server=/path/to/tursodb");
        sync_e2e_step.dependOn(&disabled.step);
    }

    const examples_step = b.step("examples", "Build and run all public examples");
    examples_step.dependOn(&run_basic_example.step);
    examples_step.dependOn(&run_file_example.step);
    examples_step.dependOn(&run_values_example.step);
    examples_step.dependOn(&run_diagnostics_example.step);
    examples_step.dependOn(&run_prepared_example.step);
    examples_step.dependOn(&run_batch_example.step);
    examples_step.dependOn(&run_transaction_example.step);
    examples_step.dependOn(&run_functions_example.step);
    examples_step.dependOn(&install_encryption_example.step);
    examples_step.dependOn(&run_ergonomic_example.step);
    if (sync) examples_step.dependOn(sync_example_step);

    const memcheck_smokes_step = b.step("build-memcheck-smokes", "Install representative executables for Valgrind");
    inline for (.{ basic_example, prepared_example, batch_example, transaction_example, functions_example, ergonomic_example }) |artifact| {
        const install_artifact = b.addInstallArtifact(artifact, .{});
        memcheck_smokes_step.dependOn(&install_artifact.step);
    }

    const prepared_benchmark = b.addExecutable(.{
        .name = "turso-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/prepared.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_prepared_benchmark = b.addRunArtifact(prepared_benchmark);
    const benchmark_step = b.step("bench", "Run prepared, one-shot, and row-iteration microbenchmarks");
    benchmark_step.dependOn(&run_prepared_benchmark.step);

    const soak_executable = b.addExecutable(.{
        .name = "turso-soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const install_soak = b.addInstallArtifact(soak_executable, .{});
    const build_soak_step = b.step("build-soak", "Install the configurable soak executable without running it");
    build_soak_step.dependOn(&install_soak.step);
    const run_soak = b.addRunArtifact(soak_executable);
    run_soak.addPassthruArgs();
    const soak_step = b.step("soak", "Run configurable lifecycle/concurrency soak: zig build soak -- [iterations workers seed]");
    soak_step.dependOn(&run_soak.step);
    const run_short_soak = b.addRunArtifact(soak_executable);
    run_short_soak.addArgs(&.{ "64", "4", "195936478" });
    const short_soak_step = b.step("test-soak", "Run the deterministic short release soak/stress gate");
    short_soak_step.dependOn(&run_short_soak.step);

    const status_module = b.createModule(.{
        .root_source_file = b.path("src/status.zig"),
        .target = target,
        .optimize = optimize,
    });
    const diagnostics_module = b.createModule(.{
        .root_source_file = b.path("src/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "status", .module = status_module }},
    });
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/value.zig"),
        .target = target,
        .optimize = optimize,
    });

    const pure_test_step = b.step("test-pure", "Run tests that do not require the native Turso library");
    const invariant_module = b.createModule(.{
        .root_source_file = b.path("src/invariant.zig"),
        .target = target,
        .optimize = optimize,
    });
    const invariant_probe = b.addExecutable(.{
        .name = "turso-ownership-invariant-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ownership_invariant_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "invariant", .module = invariant_module }},
        }),
    });
    const invariant_step = b.step(
        "test-ownership-invariants",
        "Verify ownership bookkeeping panics in every optimization mode",
    );
    const invariant_cases = [_]struct {
        name: []const u8,
        message: []const u8,
    }{
        .{
            .name = "statement-registry-underflow",
            .message = invariant.messages.statement_registry_underflow,
        },
        .{
            .name = "active-statement-mismatch",
            .message = invariant.messages.active_statement_mismatch,
        },
        .{
            .name = "connection-owner-underflow",
            .message = invariant.messages.connection_owner_underflow,
        },
        .{
            .name = "sync-io-underflow",
            .message = invariant.messages.sync_io_underflow,
        },
        .{
            .name = "aggregate-head-mismatch",
            .message = invariant.messages.aggregate_head_mismatch,
        },
    };
    for (invariant_cases) |case| {
        const run_invariant_probe = b.addRunArtifact(invariant_probe);
        run_invariant_probe.addArg(case.name);
        run_invariant_probe.expectExitCode(86);
        run_invariant_probe.expectStdErrMatch(case.message);
        invariant_step.dependOn(&run_invariant_probe.step);
    }
    pure_test_step.dependOn(invariant_step);

    const status_tests = addTestRun(b, "turso-status-tests", b.path("tests/status.zig"), target, optimize, &.{
        .{ .name = "status", .module = status_module },
    });
    pure_test_step.dependOn(&status_tests.step);

    const diagnostics_tests = addTestRun(b, "turso-diagnostics-tests", b.path("tests/diagnostics.zig"), target, optimize, &.{
        .{ .name = "diagnostics", .module = diagnostics_module },
    });
    pure_test_step.dependOn(&diagnostics_tests.step);

    const value_tests = addTestRun(b, "turso-value-tests", b.path("tests/value.zig"), target, optimize, &.{
        .{ .name = "value", .module = value_module },
    });
    pure_test_step.dependOn(&value_tests.step);

    const config_tests = addTestRun(b, "turso-config-tests", b.path("src/config.zig"), target, optimize, &.{});
    pure_test_step.dependOn(&config_tests.step);

    const partial_policy_tests = addTestRun(
        b,
        "turso-sync-partial-policy-tests",
        b.path("src/sync/partial_policy.zig"),
        target,
        optimize,
        &.{},
    );
    pure_test_step.dependOn(&partial_policy_tests.step);

    const cstring_tests = addTestRun(b, "turso-cstring-tests", b.path("src/cstring.zig"), target, optimize, &.{});
    pure_test_step.dependOn(&cstring_tests.step);

    const archive_sanitizer_tests = addTestRun(
        b,
        "turso-archive-sanitizer-tests",
        b.path("tools/sanitize_static_archive.zig"),
        target,
        optimize,
        &.{},
    );
    pure_test_step.dependOn(&archive_sanitizer_tests.step);

    const statement_io_module = b.createModule(.{
        .root_source_file = b.path("src/connection.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCImports(statement_io_module, base_c_module, sync_c_module, false);
    statement_io_module.addIncludePath(b.path("include"));
    statement_io_module.link_libc = true;
    const statement_io_tests = b.addTest(.{
        .name = "turso-statement-io-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/statement_io.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "connection", .module = statement_io_module }},
        }),
    });
    statement_io_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/fixtures/statement_io.c"),
        .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
    });
    statement_io_tests.root_module.link_libc = true;
    const run_statement_io_tests = b.addRunArtifact(statement_io_tests);
    pure_test_step.dependOn(&run_statement_io_tests.step);

    const abi_tests = b.addTest(.{
        .name = "turso-abi-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso_raw", .module = raw_module }},
        }),
    });
    abi_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/abi_probe.c"),
        .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
    });
    const run_abi_tests = b.addRunArtifact(abi_tests);
    run_abi_tests.setCwd(b.path("."));
    const abi_step = b.step("test-abi", "Run raw C ABI tests, including SELECT 1");
    abi_step.dependOn(&run_abi_tests.step);

    const sync_abi_step = b.step("test-sync-abi", "Run opt-in sync raw ABI and operation smoke tests");
    const sync_workflows_step = b.step(
        "test-sync-workflows",
        "Run deterministic sync workflow and transport tests",
    );
    if (sync_module) |module| {
        const sync_abi_tests = b.addTest(.{
            .name = "turso-sync-abi-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/sync_abi.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "turso_sync", .module = module }},
            }),
        });
        sync_abi_tests.root_module.addCSourceFile(.{
            .file = b.path("tests/sync_abi_probe.c"),
            .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
        });
        const run_sync_abi_tests = b.addRunArtifact(sync_abi_tests);
        run_sync_abi_tests.setCwd(b.path("."));
        sync_abi_step.dependOn(&run_sync_abi_tests.step);

        const sync_lifecycle_module = b.createModule(.{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
        });
        sync_lifecycle_module.addImport("turso_build_options", pinned_build_options_module);
        addCImports(sync_lifecycle_module, base_c_module, sync_c_module, true);
        sync_lifecycle_module.addIncludePath(b.path("include"));
        sync_lifecycle_module.link_libc = true;
        const sync_lifecycle_tests = b.addTest(.{
            .name = "turso-sync-lifecycle-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/sync_lifecycle.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "turso_sync", .module = sync_lifecycle_module }},
            }),
        });
        sync_lifecycle_tests.root_module.addIncludePath(b.path("include"));
        sync_lifecycle_tests.root_module.addCSourceFile(.{
            .file = b.path("tests/fixtures/sync_lifecycle.c"),
            .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
        });
        sync_lifecycle_tests.root_module.link_libc = true;
        const run_sync_lifecycle_tests = b.addRunArtifact(sync_lifecycle_tests);
        sync_abi_step.dependOn(&run_sync_lifecycle_tests.step);
        sync_workflows_step.dependOn(&run_sync_lifecycle_tests.step);

        const sync_transport_module = b.createModule(.{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
        });
        sync_transport_module.addImport("turso_build_options", pinned_build_options_module);
        addCImports(sync_transport_module, base_c_module, sync_c_module, true);
        sync_transport_module.addIncludePath(b.path("include"));
        sync_transport_module.link_libc = true;
        const sync_transport_tests = b.addTest(.{
            .name = "turso-sync-transport-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/sync_transport.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "turso_sync", .module = sync_transport_module }},
            }),
        });
        sync_transport_tests.root_module.addIncludePath(b.path("include"));
        sync_transport_tests.root_module.addCSourceFile(.{
            .file = b.path("tests/fixtures/sync_transport.c"),
            .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
        });
        sync_transport_tests.root_module.link_libc = true;
        const run_sync_transport_tests = b.addRunArtifact(sync_transport_tests);
        sync_abi_step.dependOn(&run_sync_transport_tests.step);
        sync_workflows_step.dependOn(&run_sync_transport_tests.step);

        const sync_path_safety_tests = b.addTest(.{
            .name = "turso-sync-path-safety-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/sync_path_safety.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "turso_sync", .module = sync_transport_module }},
            }),
        });
        sync_path_safety_tests.root_module.addIncludePath(b.path("include"));
        sync_path_safety_tests.root_module.addCSourceFile(.{
            .file = b.path("tests/fixtures/sync_transport.c"),
            .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
        });
        sync_path_safety_tests.root_module.link_libc = true;
        const run_sync_path_safety_tests = b.addRunArtifact(sync_path_safety_tests);
        sync_abi_step.dependOn(&run_sync_path_safety_tests.step);
    } else {
        const disabled = b.addFail("test-sync-abi requires -Dsync=true");
        sync_abi_step.dependOn(&disabled.step);
        const workflows_disabled = b.addFail("test-sync-workflows requires -Dsync=true");
        sync_workflows_step.dependOn(&workflows_disabled.step);
    }

    const mismatch_turso_module = b.createModule(.{
        .root_source_file = b.path("src/turso.zig"),
        .target = target,
        .optimize = optimize,
    });
    mismatch_turso_module.addImport("turso_build_options", pinned_build_options_module);
    addCImports(mismatch_turso_module, base_c_module, sync_c_module, false);
    mismatch_turso_module.addIncludePath(b.path("include"));
    mismatch_turso_module.link_libc = true;
    const mismatch_tests = b.addTest(.{
        .name = "turso-version-mismatch-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/version_mismatch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = mismatch_turso_module }},
        }),
    });
    mismatch_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/fixtures/mismatched_version.c"),
        .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
    });
    const run_mismatch_tests = b.addRunArtifact(mismatch_tests);
    abi_step.dependOn(&run_mismatch_tests.step);

    const ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_module.addIncludePath(b.path("include"));
    addCImports(ffi_module, base_c_module, sync_c_module, false);
    ffi_module.link_libc = true;
    const ffi_ownership_tests = b.addTest(.{
        .name = "turso-ffi-ownership-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ffi_ownership.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ffi", .module = ffi_module },
                .{ .name = "turso_c", .module = base_c_module },
            },
        }),
    });
    ffi_ownership_tests.root_module.addIncludePath(b.path("include"));
    ffi_ownership_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/fixtures/ffi_ownership.c"),
        .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
    });
    ffi_ownership_tests.root_module.link_libc = true;
    const run_ffi_ownership_tests = b.addRunArtifact(ffi_ownership_tests);
    abi_step.dependOn(&run_ffi_ownership_tests.step);

    const partial_turso_module = b.createModule(.{
        .root_source_file = b.path("src/turso.zig"),
        .target = target,
        .optimize = optimize,
    });
    partial_turso_module.addImport("turso_build_options", pinned_build_options_module);
    addCImports(partial_turso_module, base_c_module, sync_c_module, false);
    partial_turso_module.addIncludePath(b.path("include"));
    partial_turso_module.link_libc = true;
    const partial_database_tests = b.addTest(.{
        .name = "turso-partial-database-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/partial_database.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = partial_turso_module }},
        }),
    });
    partial_database_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/fixtures/partial_database.c"),
        .flags = &.{ "-std=c11", "-Werror", b.fmt("-I{s}", .{absolutePath(b, "include")}) },
    });
    partial_database_tests.root_module.link_libc = true;
    const run_partial_database_tests = b.addRunArtifact(partial_database_tests);
    abi_step.dependOn(&run_partial_database_tests.step);

    const database_tests = addTestRun(b, "turso-database-tests", b.path("tests/database.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const statement_tests = addTestRun(b, "turso-statement-tests", b.path("tests/statements.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const runtime_tests = addTestRun(b, "turso-runtime-tests", b.path("tests/runtime.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const runtime_unit_compile = b.addTest(.{
        .name = "turso-runtime-unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureModule(
        b,
        runtime_unit_compile.root_module,
        native,
        target.result,
        linkage,
        sync,
        build_options_module,
        base_c_module,
        sync_c_module,
    );
    const runtime_unit_tests = b.addRunArtifact(runtime_unit_compile);
    const ergonomics_tests = addTestRun(b, "turso-ergonomics-tests", b.path("tests/ergonomics.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const transaction_tests = addTestRun(b, "turso-transaction-tests", b.path("tests/transactions.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const batch_tests = addTestRun(b, "turso-batch-tests", b.path("tests/batches.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const security_tests = if (encryption)
        addTestRun(b, "turso-security-tests", b.path("tests/security.zig"), target, optimize, &.{
            .{ .name = "turso", .module = turso_module },
        })
    else
        null;
    const function_tests = addTestRun(b, "turso-function-tests", b.path("tests/functions.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const failure_tests = addTestRun(b, "turso-failure-tests", b.path("tests/failures.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const differential_tests = addTestRun(b, "turso-differential-tests", b.path("tests/differential.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const production_tests = addTestRun(b, "turso-production-tests", b.path("tests/production.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const sql_corpus_tests = addTestRun(b, "turso-sql-corpus-tests", b.path("tests/sql_corpus.zig"), target, optimize, &.{
        .{ .name = "turso", .module = turso_module },
    });
    const durability_fixture = b.addExecutable(.{
        .name = "turso-durability-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/durability_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turso", .module = turso_module }},
        }),
    });
    const run_durability_fixture = b.addRunArtifact(durability_fixture);
    _ = run_durability_fixture.addOutputDirectoryArg("durability-scratch");
    run_durability_fixture.addArtifactArg(durability_fixture);
    const durability_step = b.step("test-durability", "Run abrupt-exit WAL durability fixture");
    durability_step.dependOn(&run_durability_fixture.step);
    const security_step = b.step("test-security", "Run encryption and process-global logger security tests");
    if (security_tests) |run| {
        security_step.dependOn(&run.step);
    } else {
        const disabled = b.addFail("test-security requires -Dencryption=true");
        security_step.dependOn(&disabled.step);
    }
    const safe_step = b.step("test-safe", "Run safe database, statement, and row integration tests");
    const batch_step = b.step("test-batches", "Run structured batch integration tests");
    batch_step.dependOn(&batch_tests.step);
    safe_step.dependOn(&database_tests.step);
    safe_step.dependOn(&statement_tests.step);
    safe_step.dependOn(&runtime_tests.step);
    safe_step.dependOn(&runtime_unit_tests.step);
    safe_step.dependOn(&ergonomics_tests.step);
    safe_step.dependOn(&transaction_tests.step);
    safe_step.dependOn(&batch_tests.step);
    if (security_tests) |run| safe_step.dependOn(&run.step);
    safe_step.dependOn(&function_tests.step);
    safe_step.dependOn(&failure_tests.step);
    safe_step.dependOn(&differential_tests.step);
    safe_step.dependOn(&production_tests.step);
    safe_step.dependOn(&sql_corpus_tests.step);

    const test_step = b.step("test", "Run all turso.zig tests");
    test_step.dependOn(pure_test_step);
    test_step.dependOn(&compile_32_command.step);
    test_step.dependOn(&run_abi_tests.step);
    test_step.dependOn(&run_mismatch_tests.step);
    test_step.dependOn(&run_ffi_ownership_tests.step);
    test_step.dependOn(&run_partial_database_tests.step);
    test_step.dependOn(&database_tests.step);
    test_step.dependOn(&statement_tests.step);
    test_step.dependOn(&runtime_tests.step);
    test_step.dependOn(&runtime_unit_tests.step);
    test_step.dependOn(&ergonomics_tests.step);
    test_step.dependOn(&transaction_tests.step);
    test_step.dependOn(&batch_tests.step);
    if (security_tests) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&function_tests.step);
    test_step.dependOn(&failure_tests.step);
    test_step.dependOn(&differential_tests.step);
    test_step.dependOn(&production_tests.step);
    test_step.dependOn(&sql_corpus_tests.step);
    test_step.dependOn(&run_durability_fixture.step);
    test_step.dependOn(&run_short_soak.step);
    if (sync) {
        test_step.dependOn(sync_abi_step);
    }
}

fn addTestRun(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Run {
    const tests = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    return b.addRunArtifact(tests);
}

const NativeConfig = struct {
    mode: NativeMode,
    linkage: std.builtin.LinkMode,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native_path: ?[]const u8,
    turso_source: ?[]const u8,
    rust_target_override: ?[]const u8,
    allow_source_cross: bool,
    encryption: bool,
    fts: bool,
    sync: bool,
    native_artifact_step: *std.Build.Step,
};

const NativeLibrary = union(enum) {
    exact_file: struct {
        file: std.Build.LazyPath,
        add_rpath: bool,
    },
    search: struct {
        directory: ?std.Build.LazyPath,
        add_rpath: bool,
    },
};

fn configureNative(b: *std.Build, config: NativeConfig) NativeLibrary {
    switch (config.mode) {
        .system => {
            const unavailable = b.addFail("native-artifact requires -Dnative=source");
            config.native_artifact_step.dependOn(&unavailable.step);
            if (config.turso_source != null) {
                std.debug.panic("-Dturso-source is only valid with -Dnative=source", .{});
            }
            if (config.native_path) |prefix| {
                // A Windows package contains both the static archive and the
                // dynamic import library. Name-based .lib lookup is ambiguous,
                // so select the import library explicitly for dynamic mode.
                if (config.target.result.os.tag == .windows and config.linkage == .dynamic) {
                    return .{ .exact_file = .{
                        .file = .{ .cwd_relative = b.pathJoin(&.{
                            prefix,
                            "lib",
                            nativeLibraryFilename(config.target.result, config.linkage, config.sync),
                        }) },
                        .add_rpath = false,
                    } };
                }
            }
            const directory: ?std.Build.LazyPath = if (config.native_path) |prefix|
                .{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) }
            else
                null;
            return .{ .search = .{
                .directory = directory,
                .add_rpath = config.linkage == .dynamic and directory != null,
            } };
        },
        .source => {
            if (config.native_path != null) {
                std.debug.panic("-Dnative-path is only valid with -Dnative=system", .{});
            }
            if (!sourceTargetRunsOnHost(config.target, b.graph.host) and !config.allow_source_cross) {
                std.debug.panic(
                    "source-mode cross compilation requires an externally configured Cargo linker/sysroot; use -Dnative=system or explicitly opt in with -Dallow-source-cross=true",
                    .{},
                );
            }
            if (config.target.result.os.tag == .windows and config.target.result.abi != .msvc) {
                std.debug.panic(
                    "Windows source builds require an MSVC Zig target so the Zig and Rust objects use one ABI; pass -Dtarget={s}-windows-msvc from the root build",
                    .{@tagName(config.target.result.cpu.arch)},
                );
            }
            if (config.sync and !config.encryption) {
                std.debug.panic(
                    "the upstream turso_sync_sdk_kit always enables the base encryption defaults; -Dsync=true cannot honor -Dencryption=false",
                    .{},
                );
            }
            if (config.sync and config.fts) {
                std.debug.panic(
                    "the upstream turso_sync_sdk_kit does not expose an fts feature; -Dsync=true cannot honor -Dfts=true",
                    .{},
                );
            }

            const source_root: std.Build.LazyPath = if (config.turso_source) |path|
                b.graph.cwdRelativePath(absolutePath(b, path))
            else blk: {
                const dependency = b.lazyDependency("turso_native", .{}) orelse return .{
                    .search = .{ .directory = null, .add_rpath = false },
                };
                break :blk dependency.path("");
            };
            const rust_target = config.rust_target_override orelse rustTarget(config.target.result);
            const profile = if (config.optimize == .debug) "dev" else "lib-release";
            const profile_directory = if (config.optimize == .debug) "debug" else "lib-release";
            const feature_key = featureCacheKey(config.encryption, config.fts);
            const native_name = nativeLibraryName(config.sync);
            const cargo_target_subpath = if (config.target.result.abi == .musl)
                b.pathJoin(&.{
                    "turso-cargo",
                    native_name,
                    rust_target,
                    profile_directory,
                    feature_key,
                    @tagName(config.linkage),
                })
            else
                b.pathJoin(&.{
                    "turso-cargo",
                    native_name,
                    rust_target,
                    profile_directory,
                    feature_key,
                });
            const cargo_target_path = std.Build.LazyPath.cache_root.path(b, cargo_target_subpath);

            const cargo = b.addSystemCommand(&.{
                "bash",
                absolutePath(b, "tools/run-cargo-build.sh"),
            });
            cargo.addDirectoryArg(source_root);
            cargo.addDirectoryArg(cargo_target_path);
            cargo.addArg(cargoHomePath(b) orelse "-");
            cargo.addArg(if (config.target.result.os.tag == .windows) "windows" else "unix");
            cargo.addArg(rust_target);
            cargo.addArg(if (config.target.result.abi == .musl and config.linkage == .dynamic) "true" else "false");
            cargo.addArgs(&.{
                "build",
                "--locked",
                "-p",
                native_name,
                "--target",
                rust_target,
            });
            cargo.addArgs(&.{ "--profile", profile, "--no-default-features" });
            if (featureList(b, config.encryption, config.fts, config.sync)) |features| {
                cargo.addArgs(&.{ "--features", features });
            }
            cargo.setEnvironmentVariable("CARGO_TERM_COLOR", "always");
            // Upstream's build script otherwise embeds the current time and watches
            // whichever enclosing Git repository Cargo happens to discover. Pinning
            // the tagged commit time makes artifacts reproducible and cache-stable.
            cargo.setEnvironmentVariable("SOURCE_DATE_EPOCH", "1787997620");
            const cargo_home = cargoHomePath(b);

            const filename = nativeLibraryFilename(config.target.result, config.linkage, config.sync);
            const built_library = cargo_target_path.path(b, b.pathJoin(&.{
                rust_target,
                profile_directory,
                filename,
            }));

            // Cargo needs a stable target directory for incremental rebuilds, while Zig
            // needs a generated LazyPath to order native compilation before consumers.
            const staged = b.addWriteFiles();
            staged.step.dependOn(&cargo.step);
            const staged_library = staged.addCopyFile(built_library, filename);
            // Rust staticlibs bundle compiler-builtins object files from the host
            // toolchain. Besides overlapping Zig's compiler runtime, those objects
            // can retain non-remappable Cargo-registry paths. Final Zig consumers
            // already link the required compiler runtime, so omit the duplicate
            // Rust members on every supported static target.
            const library = if (config.linkage == .static)
                sanitizeStaticArchive(
                    b,
                    staged_library,
                    filename,
                    source_root,
                    cargo_target_path,
                    cargo_home,
                )
            else if (config.target.result.os.tag == .macos)
                normalizeMacOSDynamicLibrary(b, staged_library, filename)
            else
                staged_library;
            const install_library = b.addInstallFileWithDir(library, .lib, filename);
            config.native_artifact_step.dependOn(&install_library.step);
            if (config.linkage == .dynamic) {
                b.getInstallStep().dependOn(&install_library.step);
                if (config.target.result.os.tag == .windows) {
                    const dll_name = b.fmt("{s}.dll", .{native_name});
                    const built_dll = cargo_target_path.path(b, b.pathJoin(&.{
                        rust_target,
                        profile_directory,
                        dll_name,
                    }));
                    const dll = staged.addCopyFile(built_dll, dll_name);
                    const install_dll = b.addInstallFileWithDir(dll, .bin, dll_name);
                    b.getInstallStep().dependOn(&install_dll.step);
                    config.native_artifact_step.dependOn(&install_dll.step);
                }
            }
            return .{ .exact_file = .{
                .file = library,
                .add_rpath = config.linkage == .dynamic and config.target.result.os.tag != .windows,
            } };
        },
    }
}

fn sanitizeStaticArchive(
    b: *std.Build,
    source: std.Build.LazyPath,
    filename: []const u8,
    dependency_root: std.Build.LazyPath,
    cargo_target_path: std.Build.LazyPath,
    cargo_home: ?[]const u8,
) std.Build.LazyPath {
    const sanitizer = b.addExecutable(.{
        .name = "turso-sanitize-static-archive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sanitize_static_archive.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run = b.addRunArtifact(sanitizer);
    run.addArg(b.graph.zig_exe);
    run.addFileArg(source);
    const output = run.addOutputFileArg(filename);
    run.addDirectoryArg(dependency_root);
    run.addDirectoryArg(cargo_target_path);
    if (cargo_home) |path| run.addArg(path);
    return output;
}

fn normalizeMacOSDynamicLibrary(
    b: *std.Build,
    source: std.Build.LazyPath,
    filename: []const u8,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{
        "bash",
        absolutePath(b, "tools/normalize-macos-dylib.sh"),
    });
    run.addFileArg(source);
    const output = run.addOutputFileArg(filename);
    run.addArg(b.fmt("@rpath/{s}", .{filename}));
    return output;
}

fn cargoHomePath(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("CARGO_HOME")) |path| {
        return absolutePath(b, path);
    }
    if (b.graph.environ_map.get("HOME")) |home| {
        return b.pathJoin(&.{ home, ".cargo" });
    }
    return null;
}

fn sourceTargetRunsOnHost(target: std.Build.ResolvedTarget, host: std.Build.ResolvedTarget) bool {
    if (target.query.isNative()) return true;
    if (target.result.cpu.arch != host.result.cpu.arch or target.result.os.tag != host.result.os.tag) {
        return false;
    }
    if (target.result.abi == host.result.abi) return true;

    // Zig currently resolves an unspecified native Windows ABI to GNU, while
    // the installed Rust host toolchain and SDK Kit use MSVC. An explicit MSVC
    // target on the same Windows architecture is still a target-native build.
    return builtin.os.tag == .windows and target.result.abi == .msvc;
}

fn configureModule(
    b: *std.Build,
    module: *std.Build.Module,
    native: NativeLibrary,
    target: std.Target,
    linkage: std.builtin.LinkMode,
    sync: bool,
    build_options: *std.Build.Module,
    base_c_module: *std.Build.Module,
    sync_c_module: *std.Build.Module,
) void {
    module.addIncludePath(b.path("include"));
    module.addImport("turso_build_options", build_options);
    addCImports(module, base_c_module, sync_c_module, sync);
    module.link_libc = true;

    switch (native) {
        .exact_file => |exact| {
            module.addObjectFile(exact.file);
            if (exact.add_rpath) {
                // The generated path runs directly from the build cache. The
                // relocatable path covers installed executables paired with
                // the library installed by this package's install step.
                module.addRPath(exact.file.dirname());
                switch (target.os.tag) {
                    .linux => module.addRPathSpecial("$ORIGIN/../lib"),
                    .macos => module.addRPathSpecial("@loader_path/../lib"),
                    else => {},
                }
            }
        },
        .search => |search| {
            if (search.directory) |directory| {
                module.addLibraryPath(directory);
                if (search.add_rpath) module.addRPath(directory);
            }
            module.linkSystemLibrary(nativeLibraryName(sync), .{
                .needed = linkage == .dynamic,
                .use_pkg_config = .no,
                .preferred_link_mode = linkage,
                .search_strategy = .paths_first,
            });
        },
    }

    if (linkage == .static) linkStaticPlatformLibraries(module, target);
}

fn addCImports(
    module: *std.Build.Module,
    base_c_module: *std.Build.Module,
    sync_c_module: *std.Build.Module,
    sync: bool,
) void {
    module.addImport("turso_c", base_c_module);
    if (sync) module.addImport("turso_sync_c", sync_c_module);
}

fn featureList(b: *std.Build, encryption: bool, fts: bool, sync: bool) ?[]const u8 {
    if (sync) return if (encryption) "pure-rust-crypto" else null;
    if (encryption and fts) return "encryption,pure-rust-crypto,fts";
    if (encryption) return "encryption,pure-rust-crypto";
    if (fts) return "fts";
    _ = b;
    return null;
}

fn featureCacheKey(encryption: bool, fts: bool) []const u8 {
    if (encryption and fts) return "encryption-fts";
    if (encryption) return "encryption";
    if (fts) return "fts";
    return "minimal";
}

fn rustTarget(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => switch (target.abi) {
                .gnu => "x86_64-unknown-linux-gnu",
                .musl => "x86_64-unknown-linux-musl",
                else => unsupportedTarget(target),
            },
            .aarch64 => switch (target.abi) {
                .gnu => "aarch64-unknown-linux-gnu",
                .musl => "aarch64-unknown-linux-musl",
                else => unsupportedTarget(target),
            },
            else => unsupportedTarget(target),
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => unsupportedTarget(target),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .msvc) "x86_64-pc-windows-msvc" else unsupportedTarget(target),
            .aarch64 => if (target.abi == .msvc) "aarch64-pc-windows-msvc" else unsupportedTarget(target),
            else => unsupportedTarget(target),
        },
        else => unsupportedTarget(target),
    };
}

fn unsupportedTarget(target: std.Target) noreturn {
    std.debug.panic(
        "unsupported source-build target {s}-{s}-{s}; use -Dnative=system or provide -Drust-target=<triple>",
        .{ @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi) },
    );
}

fn nativeLibraryName(sync: bool) []const u8 {
    return if (sync) "turso_sync_sdk_kit" else "turso_sdk_kit";
}

fn nativeLibraryFilename(target: std.Target, linkage: std.builtin.LinkMode, sync: bool) []const u8 {
    if (sync) {
        if (linkage == .static) return if (target.os.tag == .windows) "turso_sync_sdk_kit.lib" else "libturso_sync_sdk_kit.a";
        return switch (target.os.tag) {
            .windows => "turso_sync_sdk_kit.dll.lib",
            .macos => "libturso_sync_sdk_kit.dylib",
            else => "libturso_sync_sdk_kit.so",
        };
    }
    if (linkage == .static) return if (target.os.tag == .windows) "turso_sdk_kit.lib" else "libturso_sdk_kit.a";
    return switch (target.os.tag) {
        .windows => "turso_sdk_kit.dll.lib",
        .macos => "libturso_sdk_kit.dylib",
        else => "libturso_sdk_kit.so",
    };
}

fn linkStaticPlatformLibraries(module: *std.Build.Module, target: std.Target) void {
    const no_pkg_config: std.Build.Module.LinkSystemLibraryOptions = .{ .use_pkg_config = .no };
    switch (target.os.tag) {
        .linux => {
            inline for (&.{ "gcc_s", "util", "rt", "pthread", "m", "dl" }) |library| {
                module.linkSystemLibrary(library, no_pkg_config);
            }
        },
        .windows => {
            inline for (&.{ "bcrypt", "advapi32", "kernel32", "ntdll", "userenv", "ws2_32", "dbghelp" }) |library| {
                module.linkSystemLibrary(library, no_pkg_config);
            }
        },
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkSystemLibrary("System", no_pkg_config);
            module.linkSystemLibrary("m", no_pkg_config);
        },
        else => {},
    }
}

fn absolutePath(b: *std.Build, path: []const u8) []const u8 {
    return if (std.fs.path.isAbsolute(path))
        path
    else
        b.root.joinString(b.allocator, path) catch @panic("OOM");
}

fn readWorkspaceVersion(b: *std.Build, source_path: []const u8) []const u8 {
    const cargo_toml = b.pathJoin(&.{ absolutePath(b, source_path), "Cargo.toml" });
    const contents = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        cargo_toml,
        b.allocator,
        .limited(1024 * 1024),
    ) catch |err| {
        std.debug.panic("cannot read Turso workspace manifest {s}: {s}", .{ cargo_toml, @errorName(err) });
    };

    var in_workspace_package = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_workspace_package = std.mem.eql(u8, line, "[workspace.package]");
            continue;
        }
        if (!in_workspace_package or !std.mem.startsWith(u8, line, "version")) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
        return b.allocator.dupe(u8, value[1 .. value.len - 1]) catch @panic("OOM");
    }
    std.debug.panic("Turso workspace version is missing from {s}", .{cargo_toml});
}
