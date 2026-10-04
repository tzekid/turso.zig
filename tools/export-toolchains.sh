#!/usr/bin/env bash
# Expose the pinned Zig and the Rust toolchain of the pinned Turso source to CI.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zig_version=$(<"$repo_root/.zigversion")
rust_toolchain=1.88 # rust-toolchain.toml of the Turso commit in src/version.zig

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
