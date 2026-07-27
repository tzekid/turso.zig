#!/usr/bin/env bash
set -euo pipefail

archive=
work_root=
sidecar=
skip_consumer=false

usage() {
    cat <<'EOF'
usage: tools/smoke-release.sh --archive FILE --work-root DIR [options]

Options:
  --sidecar FILE       defaults to FILE.sha256
  --skip-consumer      validate package contents without compiling the consumer

The smoke runs only from the extracted archive with fresh Zig caches. It checks
the archive and internal checksums, manifest/provenance, licenses, header digest,
ABI exports, path leaks, and the extracted tests/consumer fixture.
EOF
}

while (($#)); do
    case "$1" in
        --archive) archive=${2:?}; shift 2 ;;
        --work-root) work_root=${2:?}; shift 2 ;;
        --sidecar) sidecar=${2:?}; shift 2 ;;
        --skip-consumer) skip_consumer=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

fail() {
    echo "smoke-release: $*" >&2
    exit 1
}

build_path_leak() {
    strings -a "$1" |
        LC_ALL=C grep -E '\.zig-cache|(^|[/\\])zig-pkg([/\\]|$)|cargo-target|[/\\]\.cargo[/\\]registry' |
        sed -n '1p' || true
}

for command in jq sha256sum tar strings zig; do
    command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

[[ -f "$archive" ]] || fail "archive not found: $archive"
archive=$(realpath "$archive")
archive_dir=$(dirname -- "$archive")
archive_name=$(basename -- "$archive")
[[ -n "$work_root" ]] || fail "--work-root is required"
mkdir -p -- "$work_root"
work_root=$(CDPATH='' cd -- "$work_root" && pwd -P)
if [[ -z "$sidecar" ]]; then sidecar="$archive.sha256"; fi
[[ -f "$sidecar" ]] || fail "archive checksum sidecar not found: $sidecar"

expected_archive_sha=$(awk 'NF >= 1 { print $1; exit }' "$sidecar")
[[ "$expected_archive_sha" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid archive checksum sidecar"
actual_archive_sha=$(sha256sum "$archive" | awk '{print $1}')
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || fail "archive checksum mismatch"

entries_file="$work_root/archive-entries.txt"
(
    cd -- "$archive_dir"
    tar -tzf "$archive_name"
) >"$entries_file"
[[ -s "$entries_file" ]] || fail "archive is empty"
if awk '
    /^\// { bad = 1 }
    /(^|\/)\.\.?(\/|$)/ { bad = 1 }
    END { exit bad ? 0 : 1 }
' "$entries_file"; then
    fail "archive contains an absolute or traversal path"
fi
top_count=$(awk -F/ 'NF { print $1 }' "$entries_file" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')
[[ "$top_count" == 1 ]] || fail "archive must contain exactly one top-level directory"
top_name=$(awk -F/ 'NF { print $1; exit }' "$entries_file")

extract_root="$work_root/extracted"
rm -rf -- "$extract_root"
mkdir -p -- "$extract_root"
(
    cd -- "$archive_dir"
    tar -xzf "$archive_name" -C "$extract_root"
)
package_root="$extract_root/$top_name"
[[ -d "$package_root" ]] || fail "top-level package directory is missing"

for path in manifest.json SHA256SUMS LICENSE NOTICE licenses/turso/LICENSE.md licenses/turso/NOTICE.md include/turso.h tools/check-abi-symbols.sh tests/expected-base-symbols.txt tests/consumer/build.zig tests/consumer/build.zig.zon tests/consumer/src/main.zig; do
    [[ -s "$package_root/$path" ]] || fail "required packaged file is missing or empty: $path"
done

(
    cd "$package_root"
    sha256sum -c SHA256SUMS
)

manifest="$package_root/manifest.json"
jq -e '
    .schema_version == 1 and
    .package.name == "turso.zig" and
    (.package.version | type == "string" and length > 0) and
    (.package.source_commit | test("^[0-9a-f]{40}$")) and
    .upstream.version == "0.7.0" and
    .upstream.tag == "v0.7.0" and
    .upstream.tag_object == "c401a2e44e1a3b0435b4e8d5501e945283d2ba10" and
    .upstream.commit == "e7cb62a8bd2f3655a661a621ee389365c1a1e43e" and
    .upstream.zig_package_hash == "N-V-__8AACo_qQJTwztGl0T0AuqLsTAAQiDSBvZ8lTdECpBN" and
    .upstream.header_sha256 == "14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb" and
    (.build.kind == "source" or .build.kind == "native") and
    (.build.sync_enabled | type == "boolean") and
    (.build.features | type == "array" and length > 0) and
    .build.optimize == "ReleaseSafe" and
    (.build.ci_run_url | test("^https://github\\.com/[^/]+/[^/]+/actions/runs/[0-9]+")) and
    (if .build.kind == "native" then
        (.build.cpu_baseline | type == "string" and length > 0) and
        (.build.minimum_platform | type == "string" and length > 0)
     else .build.cpu_baseline == null and .build.minimum_platform == null end) and
    .tools.zig == "0.16.0" and
    (.licenses.wrapper.license_sha256 | test("^[0-9a-f]{64}$")) and
    (.licenses.wrapper.notice_sha256 | test("^[0-9a-f]{64}$")) and
    (.licenses.upstream.license_sha256 | test("^[0-9a-f]{64}$")) and
    (.licenses.upstream.notice_sha256 | test("^[0-9a-f]{64}$")) and
    .reproducibility.source_date_epoch == 1783955531 and
    .reproducibility.normalized_owner == 0 and
    .reproducibility.normalized_group == 0
' "$manifest" >/dev/null || fail "manifest schema or pinned provenance is invalid"

sync_enabled=$(jq -r '.build.sync_enabled' "$manifest")
if [[ "$sync_enabled" == true ]]; then
    for path in include/turso_sync.h tests/expected-sync-symbols.txt src/sync.zig; do
        [[ -s "$package_root/$path" ]] || fail "required packaged sync file is missing or empty: $path"
    done
    jq -e '
        .upstream.sync_header_sha256 == "38b9dc73fc2fe45c3d86d69ff2ad48b8c99d693a4462514ea50fb876aba6ee35" and
        .build.features == ["pure-rust-crypto"] and
        .abi.variant == "sync" and
        .abi.headers == ["include/turso.h", "include/turso_sync.h"] and
        .abi.symbol_manifests == ["tests/expected-base-symbols.txt", "tests/expected-sync-symbols.txt"] and
        .abi.symbol_count == 77
    ' "$manifest" >/dev/null || fail "sync package manifest is inconsistent"
else
    [[ ! -e "$package_root/include/turso_sync.h" ]] || fail "base package contains the sync header"
    [[ ! -e "$package_root/tests/expected-sync-symbols.txt" ]] || fail "base package contains the sync symbol manifest"
    jq -e '
        .upstream.sync_header_sha256 == null and
        .abi.variant == "base" and
        .abi.headers == ["include/turso.h"] and
        .abi.symbol_manifests == ["tests/expected-base-symbols.txt"] and
        .abi.symbol_count == 48
    ' "$manifest" >/dev/null || fail "base package manifest is inconsistent"
fi

for license_key in wrapper.license wrapper.notice upstream.license upstream.notice; do
    owner=${license_key%%.*}
    item=${license_key##*.}
    license_path=$(jq -r ".licenses.$owner.${item}_path" "$manifest")
    license_sha=$(jq -r ".licenses.$owner.${item}_sha256" "$manifest")
    [[ -s "$package_root/$license_path" ]] || fail "manifest license path is missing: $license_path"
    [[ "$(sha256sum "$package_root/$license_path" | awk '{print $1}')" == "$license_sha" ]] || fail "manifest license digest mismatch: $license_path"
done

header_sha=$(sed -n '/^#ifndef TURSO_H/,$p' "$package_root/include/turso.h" | sha256sum | awk '{print $1}')
manifest_header_sha=$(jq -r '.upstream.header_sha256' "$manifest")
[[ "$header_sha" == "$manifest_header_sha" ]] || fail "packaged header digest mismatch"
if [[ "$sync_enabled" == true ]]; then
    sync_header_sha=$(sed -n '/^#ifndef TURSO_SYNC_H/,$p' "$package_root/include/turso_sync.h" | sha256sum | awk '{print $1}')
    manifest_sync_header_sha=$(jq -r '.upstream.sync_header_sha256' "$manifest")
    [[ "$sync_header_sha" == "$manifest_sync_header_sha" ]] || fail "packaged sync header digest mismatch"
fi

if [[ -n "$(build_path_leak "$manifest")" ]]; then
    fail "manifest contains a build-cache path"
fi

kind=$(jq -r '.build.kind' "$manifest")
linkage=$(jq -r '.build.linkage' "$manifest")
target=$(jq -r '.build.target' "$manifest")
zig_target_args=()
case "$target" in
    source) ;;
    x86_64-unknown-linux-gnu) zig_target_args=(-Dtarget=x86_64-linux-gnu) ;;
    aarch64-unknown-linux-gnu) zig_target_args=(-Dtarget=aarch64-linux-gnu) ;;
    # These package lanes execute on matching native macOS runners. Keeping
    # the compiler target native lets Zig discover the active Apple SDK and
    # its frameworks; the package target above remains independently audited.
    x86_64-apple-darwin|aarch64-apple-darwin) zig_target_args=(-Dtarget=native) ;;
    x86_64-pc-windows-msvc) zig_target_args=(-Dtarget=x86_64-windows-msvc) ;;
    aarch64-pc-windows-msvc) zig_target_args=(-Dtarget=aarch64-windows-msvc) ;;
    *) fail "native package has no Zig target mapping: $target" ;;
esac
native_name=turso_sdk_kit
abi_symbol_count=48
abi_args=(
    --header "$package_root/include/turso.h"
    --expected "$package_root/tests/expected-base-symbols.txt"
)
if [[ "$sync_enabled" == true ]]; then
    native_name=turso_sync_sdk_kit
    abi_symbol_count=77
    abi_args+=(
        --sync
        --sync-header "$package_root/include/turso_sync.h"
        --sync-expected "$package_root/tests/expected-sync-symbols.txt"
    )
fi

if [[ "$kind" == source ]]; then
    [[ "$(jq -r '.native' "$manifest")" == null ]] || fail "source package unexpectedly contains native metadata"
    "$package_root/tools/check-abi-symbols.sh" "${abi_args[@]}" --header-only
else
    native_rel=$(jq -r '.native.path' "$manifest")
    [[ "$native_rel" != /* && "$native_rel" != ../* && "$native_rel" != *'/../'* ]] || fail "unsafe native path in manifest"
    native_file="$package_root/$native_rel"
    [[ -s "$native_file" ]] || fail "manifest native library is missing"
    [[ "$(sha256sum "$native_file" | awk '{print $1}')" == "$(jq -r '.native.sha256' "$manifest")" ]] || fail "native library digest mismatch"
    [[ "$(wc -c < "$native_file" | tr -d '[:space:]')" == "$(jq -r '.native.size_bytes' "$manifest")" ]] || fail "native library size mismatch"
    [[ "$(jq -r '.native.library_name' "$manifest")" == "$native_name" ]] || fail "native library name does not match selected SDK Kit variant"
    [[ "$(jq -r '.native.abi_symbol_count' "$manifest")" == "$abi_symbol_count" ]] || fail "native ABI symbol count does not match selected SDK Kit variant"
    "$package_root/tools/check-abi-symbols.sh" "${abi_args[@]}" "$native_file"

    evidence_rel=$(jq -r '.native.dependency_evidence.path' "$manifest")
    evidence_file="$package_root/$evidence_rel"
    [[ -s "$evidence_file" ]] || fail "native dependency evidence is missing"
    [[ "$(sha256sum "$evidence_file" | awk '{print $1}')" == "$(jq -r '.native.dependency_evidence.sha256' "$manifest")" ]] || fail "native dependency evidence digest mismatch"
    grep -Fx "target=$target" "$evidence_file" >/dev/null || fail "native dependency evidence target mismatch"
    if [[ "$linkage" == static ]]; then
        grep -F 'native-static-libs' "$evidence_file" >/dev/null || fail "static dependency evidence is invalid"
        grep -E "^command=.*-p[[:space:]]+$native_name([[:space:]]|$)" "$evidence_file" >/dev/null ||
            fail "static dependency evidence names the wrong SDK Kit variant"
        grep -E '^output=.+$' "$evidence_file" >/dev/null || fail "static dependency evidence is empty"
    else
        grep -E '^command=(readelf|otool|llvm-readobj|dumpbin)([[:space:]]|$)' "$evidence_file" >/dev/null || fail "dynamic dependency evidence is invalid"
        grep -E "^command=.*$native_name" "$evidence_file" >/dev/null ||
            fail "dynamic dependency evidence names the wrong SDK Kit variant"
        grep -E '^required=.+$' "$evidence_file" >/dev/null || fail "dynamic dependency evidence is empty"
        case "$target" in
            *apple-darwin)
                grep -Fx "install_name=@rpath/lib$native_name.dylib" "$evidence_file" >/dev/null ||
                    fail "Darwin dependency evidence has a non-portable dylib install name"
                ;;
        esac
    fi

    if [[ -n "$(build_path_leak "$native_file")" ]]; then
        fail "native library contains a build-cache path"
    fi

    case "$target:$linkage:$native_rel" in
        *linux*:static:"lib/lib$native_name.a") ;;
        *linux*:dynamic:"lib/lib$native_name.so") ;;
        *macos*:static:"lib/lib$native_name.a"|*darwin*:static:"lib/lib$native_name.a") ;;
        *macos*:dynamic:"lib/lib$native_name.dylib"|*darwin*:dynamic:"lib/lib$native_name.dylib") ;;
        *windows*:static:"lib/$native_name.lib") ;;
        *windows*:dynamic:"bin/$native_name.dll")
            import_rel=$(jq -r '.native.import_library.path // empty' "$manifest")
            [[ "$import_rel" == "lib/$native_name.dll.lib" && -s "$package_root/$import_rel" ]] || fail "Windows dynamic import library is missing or belongs to the other SDK Kit variant"
            [[ "$(sha256sum "$package_root/$import_rel" | awk '{print $1}')" == "$(jq -r '.native.import_library.sha256' "$manifest")" ]] || fail "Windows import library digest mismatch"
            ;;
        *) fail "native manifest path does not match target/linkage" ;;
    esac
fi

if ! $skip_consumer; then
    consumer="$package_root/tests/consumer"
    local_cache="$work_root/zig-cache"
    global_cache="$work_root/zig-global-cache"
    rm -rf -- "$local_cache" "$global_cache" "$consumer/zig-pkg" "$consumer/zig-out"
    mkdir -p -- "$local_cache" "$global_cache"
    if [[ "$sync_enabled" == true ]]; then
        cat >"$consumer/build.zig" <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option([]const u8, "native", "Forwarded turso native mode") orelse "source";
    const linkage = b.option([]const u8, "linkage", "Forwarded turso linkage mode") orelse "static";
    const native_path = b.option([]const u8, "native-path", "Forwarded turso native prefix");
    const sync_enabled = b.option(bool, "sync", "Require the public sync module") orelse false;
    if (!sync_enabled) @panic("sync package smoke requires -Dsync=true");
    const turso = if (native_path) |path|
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = native,
            .linkage = linkage,
            .@"native-path" = path,
            .sync = true,
        })
    else
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = native,
            .linkage = linkage,
            .sync = true,
        });

    const executable = b.addExecutable(.{
        .name = "turso-sync-consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turso_sync", .module = turso.module("turso_sync") },
            },
        }),
    });
    const run = b.addRunArtifact(executable);
    b.step("run", "Build and run the sync package smoke test").dependOn(&run.step);
}
EOF
        cat >"$consumer/src/main.zig" <<'EOF'
const std = @import("std");
const sync = @import("turso_sync");

pub fn main() !void {
    _ = sync.LocalConfig{ .path = ":memory:" };
    const reported = sync.raw.c.turso_version();
    if (reported == null) return error.MissingVersion;
    if (!std.mem.eql(u8, sync.version.upstream, std.mem.span(reported))) {
        return error.VersionMismatch;
    }
}
EOF
    fi
    sync_args=(-Dsync="$sync_enabled")
    if [[ "$kind" == source ]]; then
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build run --cache-dir "$local_cache" "${zig_target_args[@]}" -Dnative=source -Dlinkage=static "${sync_args[@]}" -Doptimize=ReleaseSafe
        )
        # Prove the fetched dependency graph and Cargo crates are sufficient for
        # a new local build graph with all network access disabled at the tools.
        rm -rf -- "$local_cache" "$consumer/zig-out"
        mkdir -p -- "$local_cache"
        (
            cd "$consumer"
            CARGO_NET_OFFLINE=true ZIG_GLOBAL_CACHE_DIR="$global_cache" \
                zig build run --system "$consumer/zig-pkg" --cache-dir "$local_cache" \
                "${zig_target_args[@]}" -Dnative=source -Dlinkage=static "${sync_args[@]}" -Doptimize=ReleaseSafe
        )
    else
        if [[ "$target" == *windows* && "$linkage" == dynamic ]]; then
            export PATH="$package_root/bin:$PATH"
        fi
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build run --cache-dir "$local_cache" "${zig_target_args[@]}" -Dnative=system -Dnative-path="$package_root" -Dlinkage="$linkage" "${sync_args[@]}" -Doptimize=ReleaseSafe
        )
    fi
fi

echo "release smoke OK: $archive"
