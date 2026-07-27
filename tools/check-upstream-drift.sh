#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:?usage: check-upstream-drift.sh OUTPUT_DIR [UPSTREAM_ROOT]}
upstream_root=${2:-}
temporary_root=

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

if [[ -z "$upstream_root" ]]; then
  temporary_root=$(mktemp -d)
  upstream_root="$temporary_root/turso"
  git clone --depth 1 https://github.com/tursodatabase/turso.git "$upstream_root"
fi
trap 'if [[ -n "$temporary_root" ]]; then rm -rf "$temporary_root"; fi' EXIT

upstream_root=$(cd "$upstream_root" && pwd)
upstream_header="$upstream_root/sdk-kit/turso.h"
upstream_sync_header="$upstream_root/sync/sdk-kit/turso_sync.h"
test -f "$upstream_header"
test -f "$upstream_sync_header"

commit=$(git -C "$upstream_root" rev-parse HEAD)
printf '%s\n' \
  "production_pin=v0.7.0" \
  "production_commit=e7cb62a8bd2f3655a661a621ee389365c1a1e43e" \
  "candidate_commit=$commit" \
  "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$output_dir/provenance.txt"

sed -n '/^#ifndef TURSO_H/,$p' "$repo_root/include/turso.h" > "$output_dir/pinned-turso.h"
cp "$upstream_header" "$output_dir/candidate-turso.h"
if diff -u "$output_dir/pinned-turso.h" "$output_dir/candidate-turso.h" > "$output_dir/header.diff"; then
  header_status=unchanged
else
  header_status=changed
fi

sed -n '/^#ifndef TURSO_SYNC_H/,$p' "$repo_root/include/turso_sync.h" > "$output_dir/pinned-turso-sync.h"
cp "$upstream_sync_header" "$output_dir/candidate-turso-sync.h"
if diff -u "$output_dir/pinned-turso-sync.h" "$output_dir/candidate-turso-sync.h" > "$output_dir/sync-header.diff"; then
  sync_header_status=unchanged
else
  sync_header_status=changed
fi

zig translate-c -I "$repo_root/include" "$output_dir/pinned-turso.h" > "$output_dir/pinned-raw.zig"
zig translate-c -I "$upstream_root/sdk-kit" "$output_dir/candidate-turso.h" > "$output_dir/candidate-raw.zig"
if diff -u "$output_dir/pinned-raw.zig" "$output_dir/candidate-raw.zig" > "$output_dir/generated-raw.diff"; then
  generated_status=unchanged
else
  generated_status=changed
fi

mkdir -p "$output_dir/pinned-include"
cp "$output_dir/pinned-turso.h" "$output_dir/pinned-include/turso.h"
zig translate-c \
  -I "$output_dir/pinned-include" \
  "$output_dir/pinned-turso-sync.h" > "$output_dir/pinned-sync-raw.zig"
zig translate-c \
  -I "$upstream_root/sdk-kit" \
  -I "$upstream_root/sync/sdk-kit" \
  "$output_dir/candidate-turso-sync.h" > "$output_dir/candidate-sync-raw.zig"
if diff -u "$output_dir/pinned-sync-raw.zig" "$output_dir/candidate-sync-raw.zig" > "$output_dir/generated-sync-raw.diff"; then
  generated_sync_status=unchanged
else
  generated_sync_status=changed
fi

set +e
(
  cd "$upstream_root"
  cargo build --locked -p turso_sdk_kit --lib --profile lib-release \
    --no-default-features --features encryption,pure-rust-crypto
) > "$output_dir/cargo-build.log" 2>&1
build_status=$?
set -e

symbols_status=not-run
smoke_status=not-run
native_links_status=not-run
if (( build_status == 0 )); then
  candidate_dir="$upstream_root/target/lib-release"
  static_library=$(find "$candidate_dir" -maxdepth 1 -type f -name 'libturso_sdk_kit.a' -print -quit)
  dynamic_library=$(find "$candidate_dir" -maxdepth 1 -type f \( -name 'libturso_sdk_kit.so' -o -name 'libturso_sdk_kit.dylib' -o -name 'turso_sdk_kit.dll' \) -print -quit)

  if [[ -n "$static_library" && -n "$dynamic_library" ]]; then
    set +e
    "$repo_root/tools/check-abi-symbols.sh" "$static_library" "$dynamic_library" > "$output_dir/exported-symbols.log" 2>&1
    symbols_code=$?
    set -e
    if (( symbols_code == 0 )); then symbols_status=compatible; else symbols_status=changed; fi

    set +e
    (
      cd "$repo_root"
      library_dir=$(dirname "$dynamic_library")
      export LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      zig test \
        -cflags -std=c11 -Werror -I"$upstream_root/sdk-kit" -- tests/abi_probe.c \
        -ODebug --dep turso_raw -Mroot=tests/abi.zig \
        -I "$upstream_root/sdk-kit" -Mturso_raw=src/raw.zig \
        -lc -L "$(dirname "$dynamic_library")" -rpath "$(dirname "$dynamic_library")" \
        -search_paths_first -lturso_sdk_kit
    ) > "$output_dir/raw-smoke.log" 2>&1
    smoke_code=$?
    set -e
    if (( smoke_code == 0 )); then smoke_status=passed; else smoke_status=failed; fi
  fi

  set +e
  (
    cd "$upstream_root"
    cargo rustc --locked -p turso_sdk_kit --lib --profile lib-release \
      --no-default-features --features encryption,pure-rust-crypto \
      -- --print native-static-libs
  ) > "$output_dir/native-static-libs.log" 2>&1
  native_links_code=$?
  set -e
  if (( native_links_code == 0 )); then native_links_status=captured; else native_links_status=failed; fi
fi

set +e
(
  cd "$repo_root"
  zig build test \
    -Dturso-source="$upstream_root" \
    -Dnative=source \
    -Dlinkage=static \
    -Doptimize=ReleaseSafe \
    -j2 \
    --summary all
) > "$output_dir/current-main-safe-suite.log" 2>&1
safe_suite_code=$?
set -e
if (( safe_suite_code == 0 )); then safe_suite_status=passed; else safe_suite_status=failed; fi

set +e
(
  cd "$repo_root"
  zig build test-sync-abi \
    -Dturso-source="$upstream_root" \
    -Dsync=true \
    -Dnative=source \
    -Dlinkage=static \
    -Doptimize=ReleaseSafe \
    -j2 \
    --summary all
) > "$output_dir/current-main-sync-suite.log" 2>&1
sync_suite_code=$?
set -e
if (( sync_suite_code == 0 )); then sync_suite_status=passed; else sync_suite_status=failed; fi

{
  echo "header=$header_status"
  echo "sync_header=$sync_header_status"
  echo "generated_raw=$generated_status"
  echo "generated_sync_raw=$generated_sync_status"
  echo "candidate_build_exit=$build_status"
  echo "exported_symbols=$symbols_status"
  echo "raw_select_1_smoke=$smoke_status"
  echo "native_static_links=$native_links_status"
  echo "safe_suite=$safe_suite_status"
  echo "sync_suite=$sync_suite_status"
  echo "production_pin_changed=no"
} | tee "$output_dir/summary.txt"
