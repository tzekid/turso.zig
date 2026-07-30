#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
classifier="$repo_root/tools/classify-development-target.sh"
promoted="$repo_root/tools/development-targets.json"
fixtures="$repo_root/tests/fixtures/development-classification"
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT

jq '.zig.version = "0.17.0-dev.1510+aaaaaaaaa"' "$promoted" >"$scratch/zig-candidate.json"
jq '.turso.commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$promoted" >"$scratch/turso-candidate.json"

[[ $("$classifier" zig "$promoted" "$promoted" | jq -r .classification) == no-change ]]
[[ $("$classifier" zig "$promoted" "$scratch/zig-candidate.json" "$fixtures/routine.json" | jq -r .classification) == routine ]]
[[ $("$classifier" zig "$promoted" "$scratch/zig-candidate.json" "$fixtures/maintenance.json" | jq -r .classification) == maintenance-required ]]
[[ $("$classifier" zig "$promoted" "$scratch/zig-candidate.json" "$fixtures/infrastructure.json" | jq -r .classification) == infrastructure-failure ]]
[[ $("$classifier" zig "$promoted" "$promoted" "$fixtures/release.json" | jq -r .classification) == release-event ]]
[[ $("$classifier" turso "$promoted" "$scratch/turso-candidate.json" "$fixtures/routine.json" | jq -r .classification) == routine ]]

first_key=$("$classifier" turso "$promoted" "$scratch/turso-candidate.json" "$fixtures/maintenance.json" | jq -r .dedupe_key)
second_key=$("$classifier" turso "$promoted" "$scratch/turso-candidate.json" "$fixtures/maintenance.json" | jq -r .dedupe_key)
[[ $first_key == "$second_key" ]]

echo "development target classification fixtures passed"
