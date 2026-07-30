#!/usr/bin/env bash
set -euo pipefail

umask 077

fail() {
    echo "disk-fault check: $*" >&2
    exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zig_bin=${ZIG:-zig}
[[ $(uname -s) == Linux ]] || fail "the syscall interposition fixture requires Linux"
getconf GNU_LIBC_VERSION >/dev/null 2>&1 ||
    fail "the syscall interposition fixture requires glibc"
command -v cc >/dev/null 2>&1 || fail "cc is required"
command -v "$zig_bin" >/dev/null 2>&1 || fail "Zig executable is required: $zig_bin"

case $(uname -m) in
    x86_64) rust_target=x86_64-unknown-linux-gnu ;;
    aarch64) rust_target=aarch64-unknown-linux-gnu ;;
    *) fail "unsupported Linux architecture: $(uname -m)" ;;
esac

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/turso-disk-fault.XXXXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
    [[ ! -e $temporary_root ]] ||
        echo "disk-fault check: failed to remove temporary artifacts" >&2
}
trap cleanup EXIT HUP INT TERM

shim="$temporary_root/libturso_disk_fault.so"
cc \
    -shared \
    -fPIC \
    -std=c11 \
    -Wall \
    -Wextra \
    -Wpedantic \
    -Werror \
    "$repo_root/tests/fixtures/disk_fault.c" \
    -ldl \
    -o "$shim"

"$zig_bin" build \
    --cache-dir "$repo_root/.zig-cache" \
    example-basic \
    -Dlinkage=dynamic \
    -Dencryption=false \
    -Doptimize=ReleaseSafe

native_lib_dir="$repo_root/.zig-cache/turso-cargo/turso_sdk_kit/$rust_target/lib-release/minimal/$rust_target/lib-release"
native_library="$native_lib_dir/libturso_sdk_kit.so"
[[ -f $native_library ]] ||
    fail "expected native library was not built"

fixture_prefix="$temporary_root/fixture"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}" \
    "$zig_bin" build \
    --build-file "$repo_root/tests/disk_fault_build.zig" \
    --cache-dir "$temporary_root/zig-cache" \
    --prefix "$fixture_prefix" \
    -Dproject-root="$repo_root" \
    -Dnative-lib-dir="$native_lib_dir" \
    -Doptimize=ReleaseSafe
fixture="$fixture_prefix/bin/turso-disk-fault-fixture"
[[ -x $fixture ]] || fail "fixture executable was not installed"

for mode in enospc short; do
    for run in 1 2 3; do
        scratch="$temporary_root/$mode-$run"
        report="$scratch/report"
        database="$scratch/fault.db"
        mkdir -p "$scratch"

        TURSO_DISK_FAULT_PATH="$database" \
            TURSO_DISK_FAULT_MODE="$mode" \
            TURSO_DISK_FAULT_AFTER=0 \
            TURSO_DISK_FAULT_REPORT="$report" \
            LD_PRELOAD="$shim" \
            "$fixture" "$mode" "$database"

        [[ -f $report ]] || fail "$mode run $run did not inject a fault"
        if [[ $mode == enospc ]]; then
            [[ $(grep -c '^enospc$' "$report") -ge 1 ]] ||
                fail "ENOSPC run $run did not reach the injected syscall"
        else
            [[ $(grep -c '^short-write$' "$report") -ge 1 ]] ||
                fail "short-write run $run did not perform a partial syscall write"
            [[ $(grep -c '^io-error$' "$report") -ge 1 ]] ||
                fail "short-write run $run did not fail its retry with EIO"
        fi
    done
done

echo "disk-fault check: ENOSPC and short-write/EIO passed 3/3 runs"
