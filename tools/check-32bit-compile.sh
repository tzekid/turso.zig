#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
cd "$repo_root"

# Compile, but deliberately do not link or execute, the native-facing safe API
# on a 32-bit usize target. This instantiates count/status/row conversion paths
# and makes accidental narrowing traps a normal aggregate-build failure.
zig test -target x86-linux-gnu -fno-emit-bin \
    --dep turso \
    -Mroot=tests/statements.zig \
    --dep turso_build_options \
    -I include \
    -Mturso=src/turso.zig \
    -Mturso_build_options=src/build_options.zig \
    -lc

echo "32-bit safe API compile OK"
