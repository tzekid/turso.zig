#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
native_library=${1:-}

[[ -f "$native_library" ]] || {
    echo "usage: tools/check-readme-example.sh PATH/TO/libturso_sdk_kit.a" >&2
    exit 64
}

source_file=$(mktemp "${TMPDIR:-/tmp}/turso-readme-example.XXXXXX.zig")
translated_header=$(mktemp "${TMPDIR:-/tmp}/turso-readme-c.XXXXXX.zig")
trap 'rm -f "$source_file" "$translated_header"' EXIT

awk '
    /^~~~zig$/ {
        blocks += 1
        if (blocks == 1) { in_block = 1; next }
    }
    in_block && /^~~~$/ { in_block = 0; exit }
    in_block { print }
    END { if (blocks != 1 || in_block) exit 1 }
' "$repo_root/README.md" > "$source_file"
[[ -s "$source_file" ]] || { echo "README Zig example is missing or empty" >&2; exit 1; }
zig translate-c -I "$repo_root/include" "$repo_root/include/turso.h" >"$translated_header"

zig build-exe -fno-emit-bin -ODebug \
    --dep turso \
    -Mroot="$source_file" \
    "$native_library" \
    --dep turso_build_options --dep turso_c \
    -I "$repo_root/include" \
    -Mturso="$repo_root/src/turso.zig" \
    -Mturso_build_options="$repo_root/src/build_options.zig" \
    -Mturso_c="$translated_header" \
    -lc -lgcc_s

echo "README Zig example compiles"
