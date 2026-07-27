#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

command -v valgrind >/dev/null 2>&1 || {
  echo "valgrind is required for the memcheck gate" >&2
  exit 1
}

# The smokes are built for the host triple but with a baseline CPU model so
# Valgrind never has to decode host-only instruction set extensions (AVX-512 and
# similar) that its VEX front end rejects. `-Dcpu=baseline` changes the Zig code
# generator only: build.zig derives the Cargo target triple from arch/os/abi
# alone, so the native SDK Kit is still built by the host Rust toolchain and no
# cross linker or sysroot is involved. `std.Target.Query.isNative()` is
# nevertheless false for any explicit CPU model, so build.zig's source-mode
# cross-compilation guard has to be opted out of explicitly for this CPU-only
# deviation. Reject every caller argument that can move the build off
# the host triple -- the Zig target and CPU, the guard opt-out itself, and
# `-Drust-target`, which overrides the derived Cargo triple directly -- so that
# opt-in can never silently widen into a real cross build the guard exists to
# stop.
for argument in "$@"; do
  case "$argument" in
  -Dtarget=* | -Dcpu=* | -Dallow-source-cross=* | -Drust-target=*)
    echo "check-valgrind.sh pins the host triple with a baseline CPU; refusing $argument" >&2
    exit 2
    ;;
  esac
done

zig build build-memcheck-smokes "$@" \
  -Doptimize=ReleaseSafe \
  -Dcpu=baseline \
  -Dallow-source-cross=true

for executable in \
  zig-out/bin/turso-basic \
  zig-out/bin/turso-prepared \
  zig-out/bin/turso-transaction \
  zig-out/bin/turso-functions \
  zig-out/bin/turso-ergonomic
do
  test -x "$executable"
  valgrind \
    --quiet \
    --error-exitcode=97 \
    --undef-value-errors=no \
    --leak-check=full \
    --show-leak-kinds=definite,indirect \
    --errors-for-leak-kinds=definite,indirect \
    "$executable"
done

echo "Valgrind lifecycle smoke OK"
