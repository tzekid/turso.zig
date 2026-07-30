#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/tools/development-targets.json"

for command in jq sha256sum; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

jq -e '
  .schema == 1 and
  (.binding_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.release_monitor.zig_last_notified | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.release_monitor.turso_last_notified | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  .zig.channel == "master" and
  (.zig.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+-dev\\.[0-9]+\\+[0-9a-f]+$")) and
  .turso.channel == "main" and
  (.turso.commit | test("^[0-9a-f]{40}$")) and
  (.turso.source_date_epoch | type == "number") and
  (.turso.base_header_sha256 | test("^[0-9a-f]{64}$")) and
  (.turso.sync_header_sha256 | test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null

binding=$(jq -er '.binding_version' "$manifest")
zig_version=$(jq -er '.zig.version' "$manifest")
turso_version=$(jq -er '.turso.declared_version' "$manifest")
turso_commit=$(jq -er '.turso.commit' "$manifest")
turso_archive=$(jq -er '.turso.archive_url' "$manifest")
turso_hash=$(jq -er '.turso.zig_package_hash' "$manifest")
base_header_sha=$(jq -er '.turso.base_header_sha256' "$manifest")
sync_header_sha=$(jq -er '.turso.sync_header_sha256' "$manifest")
turso_epoch=$(jq -er '.turso.source_date_epoch' "$manifest")
rust_toolchain=$(jq -er '.turso.rust_toolchain' "$manifest")

require_text() {
  local text=$1
  local path=$2
  grep -F -- "$text" "$repo_root/$path" >/dev/null || {
    echo "$path does not contain expected target value: $text" >&2
    exit 1
  }
}

require_text ".version = \"$binding\"" build.zig.zon
require_text ".minimum_zig_version = \"$zig_version\"" build.zig.zon
require_text ".url = \"$turso_archive\"" build.zig.zon
require_text ".hash = \"$turso_hash\"" build.zig.zon
require_text "pub const binding = \"$binding\";" src/version.zig
require_text "pub const minimum_zig = \"$zig_version\";" src/version.zig
require_text "pub const upstream = \"$turso_version\";" src/version.zig
require_text "pub const upstream_channel = \"main\";" src/version.zig
require_text "pub const upstream_commit = \"$turso_commit\";" src/version.zig
require_text "pub const upstream_header_sha256 = \"$base_header_sha\";" src/version.zig
require_text "pub const upstream_sync_header_sha256 = \"$sync_header_sha\";" src/version.zig
require_text "pub const expected_runtime_version = \"$turso_version\";" src/build_options.zig
require_text "SOURCE_DATE_EPOCH\", \"$turso_epoch\"" build.zig
require_text ".minimum_zig_version = \"$zig_version\"" tests/consumer/build.zig.zon
for workflow in ci drift extended release windows-arm-preview; do
  require_text "ZIG_VERSION: $zig_version" ".github/workflows/$workflow.yml"
done
for workflow in ci drift extended; do
  require_text "RUST_TOOLCHAIN: \"$rust_toolchain\"" ".github/workflows/$workflow.yml"
done
require_text "$zig_version" README.md
require_text "$turso_version" README.md
require_text "$turso_commit" README.md
require_text "$turso_version" docs/DEVELOPMENT_CHANNELS.md
require_text "$turso_commit" docs/DEVELOPMENT_CHANNELS.md
require_text "$turso_commit" include/turso.h
require_text "$turso_commit" include/turso_sync.h
require_text "$turso_version" NOTICE
require_text "$turso_commit" NOTICE
require_text "$base_header_sha" NOTICE
require_text "$sync_header_sha" NOTICE
for fixture in partial_database sync_lifecycle sync_transport; do
  require_text "return \"$turso_version\";" "tests/fixtures/$fixture.c"
done

actual_base_header_sha=$(
  sed -n '/^#ifndef TURSO_H/,$p' "$repo_root/include/turso.h" |
    sha256sum |
    awk '{ print $1 }'
)
actual_sync_header_sha=$(
  sed -n '/^#ifndef TURSO_SYNC_H/,$p' "$repo_root/include/turso_sync.h" |
    sha256sum |
    awk '{ print $1 }'
)
[[ $actual_base_header_sha == "$base_header_sha" ]] || {
  echo "include/turso.h body hash mismatch" >&2
  exit 1
}
[[ $actual_sync_header_sha == "$sync_header_sha" ]] || {
  echo "include/turso_sync.h body hash mismatch" >&2
  exit 1
}

echo "development targets are internally consistent"
