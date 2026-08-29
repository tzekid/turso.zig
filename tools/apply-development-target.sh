#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 zig|turso CANDIDATE_JSON" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
upstream=$1
candidate=$2
[[ $upstream == zig || $upstream == turso ]] || usage

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
promoted="$repo_root/tools/development-targets.json"
jq -e '.schema == 1' "$candidate" >/dev/null
jq -e '.schema == 1' "$promoted" >/dev/null

replace_literal() {
  local path=$1
  local old=$2
  local new=$3
  OLD_VALUE=$old NEW_VALUE=$new python3 - "$repo_root/$path" <<'PY'
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = os.environ["OLD_VALUE"]
new = os.environ["NEW_VALUE"]
content = path.read_text()
if old not in content:
    raise SystemExit(f"{path}: expected value not found: {old}")
path.write_text(content.replace(old, new))
PY
}

scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT

if [[ $upstream == zig ]]; then
  old_version=$(jq -er '.zig.version' "$promoted")
  new_version=$(jq -er '.zig.version' "$candidate")
  jq --slurpfile candidate "$candidate" '.zig = $candidate[0].zig' "$promoted" >"$scratch/manifest.json"

  paths=(
    build.zig.zon
    src/version.zig
    tests/consumer/build.zig.zon
    .github/ISSUE_TEMPLATE/bug.yml
    README.md
    CHANGELOG.md
    docs/DEVELOPMENT_CHANNELS.md
    docs/RELEASING.md
  )
  for path in "${paths[@]}"; do
    replace_literal "$path" "$old_version" "$new_version"
  done
else
  old_version=$(jq -er '.turso.declared_version' "$promoted")
  old_commit=$(jq -er '.turso.commit' "$promoted")
  old_epoch=$(jq -er '.turso.source_date_epoch' "$promoted")
  old_archive=$(jq -er '.turso.archive_url' "$promoted")
  old_package_hash=$(jq -er '.turso.zig_package_hash' "$promoted")
  old_base_hash=$(jq -er '.turso.base_header_sha256' "$promoted")
  old_sync_hash=$(jq -er '.turso.sync_header_sha256' "$promoted")

  new_version=$(jq -er '.turso.declared_version' "$candidate")
  new_commit=$(jq -er '.turso.commit' "$candidate")
  new_epoch=$(jq -er '.turso.source_date_epoch' "$candidate")
  new_archive=$(jq -er '.turso.archive_url' "$candidate")
  new_package_hash=$(jq -er '.turso.zig_package_hash' "$candidate")
  new_base_hash=$(jq -er '.turso.base_header_sha256' "$candidate")
  new_sync_hash=$(jq -er '.turso.sync_header_sha256' "$candidate")
  jq --slurpfile candidate "$candidate" '.turso = $candidate[0].turso' "$promoted" >"$scratch/manifest.json"

  replace_literal build.zig.zon "$old_archive" "$new_archive"
  replace_literal build.zig.zon "$old_package_hash" "$new_package_hash"
  replace_literal build.zig "$old_epoch" "$new_epoch"
  replace_literal src/version.zig "$old_version" "$new_version"
  replace_literal src/version.zig "$old_commit" "$new_commit"
  replace_literal src/version.zig "$old_base_hash" "$new_base_hash"
  replace_literal src/version.zig "$old_sync_hash" "$new_sync_hash"
  replace_literal src/build_options.zig "$old_version" "$new_version"
  replace_literal NOTICE "$old_version" "$new_version"
  replace_literal NOTICE "$old_commit" "$new_commit"
  replace_literal NOTICE "$old_base_hash" "$new_base_hash"
  replace_literal NOTICE "$old_sync_hash" "$new_sync_hash"
  replace_literal README.md "$old_version" "$new_version"
  replace_literal README.md "$old_commit" "$new_commit"
  for path in CHANGELOG.md docs/DEVELOPMENT_CHANNELS.md docs/RELEASING.md docs/UPSTREAM_ABI.md; do
    replace_literal "$path" "$old_version" "$new_version"
    replace_literal "$path" "$old_commit" "$new_commit"
  done
  replace_literal docs/RELEASING.md "$old_package_hash" "$new_package_hash"
  replace_literal docs/RELEASING.md "$old_base_hash" "$new_base_hash"
  replace_literal docs/RELEASING.md "$old_sync_hash" "$new_sync_hash"
  replace_literal docs/RELEASING.md "$old_epoch" "$new_epoch"
  replace_literal docs/DEVELOPMENT_CHANNELS.md "$old_package_hash" "$new_package_hash"
  replace_literal docs/DEVELOPMENT_CHANNELS.md "$old_base_hash" "$new_base_hash"
  replace_literal docs/DEVELOPMENT_CHANNELS.md "$old_sync_hash" "$new_sync_hash"
  replace_literal docs/DEVELOPMENT_CHANNELS.md "$old_epoch" "$new_epoch"

  for path in \
    tests/fixtures/partial_database.c \
    tests/fixtures/sync_lifecycle.c \
    tests/fixtures/sync_transport.c; do
    replace_literal "$path" "$old_version" "$new_version"
  done

  raw_root="https://raw.githubusercontent.com/tursodatabase/turso/$new_commit"
  curl -fsSL "$raw_root/sdk-kit/turso.h" >"$scratch/turso.h"
  curl -fsSL "$raw_root/sync/sdk-kit/turso_sync.h" >"$scratch/turso_sync.h"
  [[ $(sha256sum "$scratch/turso.h" | awk '{ print $1 }') == "$new_base_hash" ]]
  [[ $(sha256sum "$scratch/turso_sync.h" | awk '{ print $1 }') == "$new_sync_hash" ]]

  {
    printf '%s\n' '/*'
    printf ' * Vendored from https://github.com/tursodatabase/turso/blob/%s/sdk-kit/turso.h\n' "$new_commit"
    printf '%s\n' ' * Upstream channel: main'
    printf ' * Upstream commit: %s\n' "$new_commit"
    printf '%s\n' \
      ' * Copyright the Turso project contributors. Licensed under the MIT License.' \
      ' * The upstream header follows unchanged below this attribution block.' \
      ' */'
    cat "$scratch/turso.h"
  } >"$repo_root/include/turso.h"
  {
    printf '%s\n' '/*'
    printf ' * Vendored from https://github.com/tursodatabase/turso/blob/%s/sync/sdk-kit/turso_sync.h\n' "$new_commit"
    printf '%s\n' ' * Upstream channel: main'
    printf ' * Upstream commit: %s\n' "$new_commit"
    printf '%s\n' \
      ' * Copyright the Turso project contributors. Licensed under the MIT License.' \
      ' * The upstream header follows unchanged below this attribution block.' \
      ' */'
    cat "$scratch/turso_sync.h"
  } >"$repo_root/include/turso_sync.h"
fi

mv "$scratch/manifest.json" "$promoted"
"$repo_root/tools/check-development-targets.sh"
