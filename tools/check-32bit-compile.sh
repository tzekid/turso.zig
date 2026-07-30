#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
cd "$repo_root"
zig_bin=${ZIG:-zig}

# Compile, but deliberately do not link or execute, the native-facing safe API
# on a 32-bit usize target. This instantiates count/status/row conversion paths
# and makes accidental narrowing traps a normal aggregate-build failure.
translated_header=$(mktemp "${TMPDIR:-/tmp}/turso-c-32bit.XXXXXX.zig")
trap 'rm -f "$translated_header"' EXIT
"$zig_bin" translate-c -target x86-linux-gnu -I include include/turso.h >"$translated_header"
"$zig_bin" test -target x86-linux-gnu -fno-emit-bin \
    --dep turso \
    -Mroot=tests/statements.zig \
    --dep turso_build_options --dep turso_c \
    -I include \
    -Mturso=src/turso.zig \
    -Mturso_build_options=src/build_options.zig \
    -Mturso_c="$translated_header" \
    -lc

echo "32-bit safe API compile OK"
