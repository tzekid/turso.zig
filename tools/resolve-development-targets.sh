#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
write=false
if [[ ${1:-} == --write ]]; then
  write=true
  shift
fi
[[ $# -eq 0 ]] || {
  echo "usage: $0 [--write]" >&2
  exit 2
}

for command in curl git jq sha256sum; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

zig_bin=${ZIG:-zig}
command -v "$zig_bin" >/dev/null || {
  echo "Zig executable not found: $zig_bin" >&2
  exit 1
}

temporary_root=$(mktemp -d)
trap 'rm -r "$temporary_root"' EXIT

curl_args=(-fsSL --retry 3 --retry-all-errors --connect-timeout 20)
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  github_auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
else
  github_auth=()
fi

zig_index="$temporary_root/zig-index.json"
curl "${curl_args[@]}" https://ziglang.org/download/index.json > "$zig_index"
zig_version=$(jq -er '.master.version' "$zig_index")
zig_date=$(jq -er '.master.date' "$zig_index")
zig_latest_stable=$(
  jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$zig_index" |
    sort -V |
    tail -1
)

turso_commit=$(
  git ls-remote https://github.com/tursodatabase/turso.git refs/heads/main |
    awk 'NR == 1 { print $1 }'
)
[[ $turso_commit =~ ^[0-9a-f]{40}$ ]] || {
  echo "invalid Turso main commit: $turso_commit" >&2
  exit 1
}

turso_root="https://raw.githubusercontent.com/tursodatabase/turso/$turso_commit"
curl "${curl_args[@]}" "$turso_root/Cargo.toml" > "$temporary_root/Cargo.toml"
curl "${curl_args[@]}" "$turso_root/rust-toolchain.toml" > "$temporary_root/rust-toolchain.toml"
curl "${curl_args[@]}" "$turso_root/sdk-kit/turso.h" > "$temporary_root/turso.h"
curl "${curl_args[@]}" "$turso_root/sync/sdk-kit/turso_sync.h" > "$temporary_root/turso_sync.h"

turso_version=$(
  awk '
    /^\[workspace\.package\]$/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^version = "/ {
      value = $0
      sub(/^version = "/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$temporary_root/Cargo.toml"
)
rust_toolchain=$(
  awk -F'"' '/^channel = "/ { print $2; exit }' "$temporary_root/rust-toolchain.toml"
)
[[ -n $turso_version && -n $rust_toolchain ]] || {
  echo "failed to resolve Turso workspace version or Rust toolchain" >&2
  exit 1
}

commit_json="$temporary_root/commit.json"
curl "${curl_args[@]}" "${github_auth[@]}" \
  "https://api.github.com/repos/tursodatabase/turso/commits/$turso_commit" \
  > "$commit_json"
turso_timestamp=$(jq -er '.commit.committer.date' "$commit_json")
turso_latest_stable=$(
  curl "${curl_args[@]}" "${github_auth[@]}" \
    https://api.github.com/repos/tursodatabase/turso/releases/latest |
    jq -er '.tag_name | sub("^v"; "")'
)
turso_epoch=$(date -u -d "$turso_timestamp" +%s)
turso_archive="https://github.com/tursodatabase/turso/archive/$turso_commit.tar.gz"
turso_package_hash=$("$zig_bin" fetch "$turso_archive" | tail -1)

base_header_sha=$(sha256sum "$temporary_root/turso.h" | awk '{ print $1 }')
sync_header_sha=$(sha256sum "$temporary_root/turso_sync.h" | awk '{ print $1 }')

candidate="$temporary_root/development-targets.json"
jq -n \
  --arg binding_version "$(jq -er '.binding_version' "$repo_root/tools/development-targets.json")" \
  --argjson release_monitor "$(jq '.release_monitor' "$repo_root/tools/development-targets.json")" \
  --arg zig_latest_stable "$zig_latest_stable" \
  --arg turso_latest_stable "$turso_latest_stable" \
  --arg zig_version "$zig_version" \
  --arg zig_date "$zig_date" \
  --arg turso_version "$turso_version" \
  --arg turso_commit "$turso_commit" \
  --arg turso_timestamp "$turso_timestamp" \
  --argjson turso_epoch "$turso_epoch" \
  --arg turso_archive "$turso_archive" \
  --arg turso_package_hash "$turso_package_hash" \
  --arg base_header_sha "$base_header_sha" \
  --arg sync_header_sha "$sync_header_sha" \
  --arg rust_toolchain "$rust_toolchain" \
  --argjson zig_master "$(jq '.master' "$zig_index")" \
  '{
    schema: 1,
    binding_version: $binding_version,
    release_monitor: $release_monitor,
    discovered_stable: {
      zig: $zig_latest_stable,
      turso: $turso_latest_stable
    },
    zig: {
      channel: "master",
      version: $zig_version,
      date: $zig_date,
      assets: {
        "x86_64-linux": {
          url: $zig_master["x86_64-linux"].tarball,
          sha256: $zig_master["x86_64-linux"].shasum
        },
        "aarch64-linux": {
          url: $zig_master["aarch64-linux"].tarball,
          sha256: $zig_master["aarch64-linux"].shasum
        },
        "aarch64-macos": {
          url: $zig_master["aarch64-macos"].tarball,
          sha256: $zig_master["aarch64-macos"].shasum
        },
        "x86_64-windows": {
          url: $zig_master["x86_64-windows"].tarball,
          sha256: $zig_master["x86_64-windows"].shasum
        },
        "aarch64-windows": {
          url: $zig_master["aarch64-windows"].tarball,
          sha256: $zig_master["aarch64-windows"].shasum
        }
      }
    },
    turso: {
      channel: "main",
      declared_version: $turso_version,
      commit: $turso_commit,
      commit_timestamp: $turso_timestamp,
      source_date_epoch: $turso_epoch,
      archive_url: $turso_archive,
      zig_package_hash: $turso_package_hash,
      base_header_sha256: $base_header_sha,
      sync_header_sha256: $sync_header_sha,
      rust_toolchain: $rust_toolchain
    }
  }' > "$candidate"

if [[ $write == true ]]; then
  mv "$candidate" "$repo_root/tools/development-targets.json"
else
  jq . "$candidate"
fi
