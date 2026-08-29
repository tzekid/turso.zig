#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/tools/development-targets.json"

zig_version=$(jq -er '.zig.version' "$manifest")
rust_toolchain=$(jq -er '.turso.rust_toolchain' "$manifest")

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "zig_version=$zig_version"
    echo "rust_toolchain=$rust_toolchain"
  } >>"$GITHUB_OUTPUT"
fi

if [[ -n ${GITHUB_ENV:-} ]]; then
  {
    echo "ZIG_VERSION=$zig_version"
    echo "RUST_TOOLCHAIN=$rust_toolchain"
  } >>"$GITHUB_ENV"
fi

printf 'zig=%s\nrust=%s\n' "$zig_version" "$rust_toolchain"
