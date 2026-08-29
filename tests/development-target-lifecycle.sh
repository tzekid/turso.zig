#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT

current_turso=53f153e075b4ace73a5c75ff99922616e802905c
frozen_turso=176fd75c29c67f3ec7ff8557d02551688c99f795
older_turso=34b38a1a43a4449b868141c62508ab0c8376308b

printf '[]\n' >"$scratch/issues.json"
printf '[]\n' >"$scratch/pulls.json"
"$repo_root/tools/select-development-target-work.sh" \
  turso maintenance-required "$current_turso" \
  "$scratch/issues.json" "$scratch/pulls.json" >"$scratch/selection.json"
jq -e --arg revision "$current_turso" \
  '.working_revision == $revision and .source == "current" and .issue_number == null and .pull_request_number == null' \
  "$scratch/selection.json" >/dev/null

jq -n --arg revision "$frozen_turso" '[{
  number: 27,
  body: ("<!-- development-target:turso:maintenance-required -->\n<!-- development-target-working:turso:" + $revision + " -->")
}]' >"$scratch/issues.json"
"$repo_root/tools/select-development-target-work.sh" \
  turso maintenance-required "$current_turso" \
  "$scratch/issues.json" "$scratch/pulls.json" >"$scratch/selection.json"
jq -e --arg revision "$current_turso" \
  '.working_revision == $revision and .source == "issue" and .issue_number == 27' \
  "$scratch/selection.json" >/dev/null

jq -n --arg revision "$older_turso" '[{
  number: 31,
  url: "https://github.com/tzekid/turso.zig/pull/31",
  headRefName: "automation/turso-34b38a1a43a4",
  body: ("<!-- development-target-pr:turso:maintenance-required:" + $revision + " -->\n<!-- development-target-working:turso:" + $revision + " -->")
}]' >"$scratch/pulls.json"
"$repo_root/tools/select-development-target-work.sh" \
  turso maintenance-required "$current_turso" \
  "$scratch/issues.json" "$scratch/pulls.json" >"$scratch/selection.json"
jq -e --arg revision "$older_turso" \
  '.working_revision == $revision and .source == "pull-request" and .issue_number == 27 and .pull_request_number == 31' \
  "$scratch/selection.json" >/dev/null

jq -n --arg revision "$frozen_turso" '[{
  number: 28,
  body: ("<!-- development-target:turso:infrastructure-failure -->\n<!-- development-target-working:turso:" + $revision + " -->")
}]' >"$scratch/issues.json"
printf '[]\n' >"$scratch/pulls.json"
"$repo_root/tools/select-development-target-work.sh" \
  turso maintenance-required "$current_turso" \
  "$scratch/issues.json" "$scratch/pulls.json" >"$scratch/selection.json"
jq -e --arg revision "$current_turso" \
  '.working_revision == $revision and .source == "current" and .issue_number == null' \
  "$scratch/selection.json" >/dev/null

jq -n --arg old "$frozen_turso" --arg new "$current_turso" '{
  classification: "maintenance-required",
  upstream: "turso",
  old_revision: $old,
  new_revision: $new,
  reasons: ["abi is changed", "tests is failed"]
}' >"$scratch/evidence.json"
REPOSITORY=tzekid/turso.zig DEVELOPMENT_TARGET_RENDER_ONLY=true \
  "$repo_root/tools/sync-development-target-issue.sh" \
    turso maintenance-required "$frozen_turso" "$current_turso" \
    https://github.com/tzekid/turso.zig/actions/runs/33233979256 \
    "$scratch/evidence.json" https://github.com/tzekid/turso.zig/pull/31 \
    >"$scratch/body.md"
grep -Fq '<!-- development-target:turso:maintenance-required -->' "$scratch/body.md"
grep -Fq "<!-- development-target-working:turso:$frozen_turso -->" "$scratch/body.md"
grep -Fq -- "- Breaking compatibility signal: \`true\`" "$scratch/body.md"
grep -Fq -- '- Draft pull request: https://github.com/tzekid/turso.zig/pull/31' "$scratch/body.md"
grep -Fq 'gh run download 33233979256' "$scratch/body.md"

mkdir -p "$scratch/fake-bin"
cp "$repo_root/tests/fake-development-gh.sh" "$scratch/fake-bin/gh"
chmod +x "$scratch/fake-bin/gh"
printf '[]\n' >"$scratch/fake-gh-state.json"
: >"$scratch/fake-gh-labels.txt"
: >"$scratch/fake-gh-calls.txt"
PATH="$scratch/fake-bin:$PATH" \
FAKE_GH_STATE="$scratch/fake-gh-state.json" \
FAKE_GH_LABEL_LOG="$scratch/fake-gh-labels.txt" \
FAKE_GH_CALL_LOG="$scratch/fake-gh-calls.txt" \
REPOSITORY=tzekid/turso.zig \
  "$repo_root/tools/sync-development-target-issue.sh" \
    turso maintenance-required "$frozen_turso" "$frozen_turso" \
    https://github.com/tzekid/turso.zig/actions/runs/33233979256 \
    "$scratch/evidence.json" >/dev/null
PATH="$scratch/fake-bin:$PATH" \
FAKE_GH_STATE="$scratch/fake-gh-state.json" \
FAKE_GH_LABEL_LOG="$scratch/fake-gh-labels.txt" \
FAKE_GH_CALL_LOG="$scratch/fake-gh-calls.txt" \
REPOSITORY=tzekid/turso.zig \
  "$repo_root/tools/sync-development-target-issue.sh" \
    turso maintenance-required "$frozen_turso" "$current_turso" \
    https://github.com/tzekid/turso.zig/actions/runs/33233979256 \
    "$scratch/evidence.json" https://github.com/tzekid/turso.zig/pull/31 \
    >/dev/null
jq -e --arg frozen "$frozen_turso" --arg latest "$current_turso" '
  (length == 1) and
  (.[0].body | contains("State: **agent-working**")) and
  (.[0].body | contains("Working candidate: `" + $frozen + "`")) and
  (.[0].body | contains("Latest observed candidate: `" + $latest + "`"))
' "$scratch/fake-gh-state.json" >/dev/null
grep -Fxq agent-maintenance "$scratch/fake-gh-labels.txt"
grep -Fxq breaking-change "$scratch/fake-gh-labels.txt"
if grep -F -- '--assignee' "$scratch/fake-gh-calls.txt"; then
  echo "maintenance tracker must remain unassigned while automation is working" >&2
  exit 1
fi

GITHUB_OUTPUT="$scratch/outputs" GITHUB_ENV="$scratch/environment" \
  "$repo_root/tools/export-development-targets.sh" >"$scratch/exported.txt"
zig_version=$(jq -er '.zig.version' "$repo_root/tools/development-targets.json")
rust_toolchain=$(jq -er '.turso.rust_toolchain' "$repo_root/tools/development-targets.json")
grep -Fx "zig_version=$zig_version" "$scratch/outputs"
grep -Fx "rust_toolchain=$rust_toolchain" "$scratch/outputs"
grep -Fx "ZIG_VERSION=$zig_version" "$scratch/environment"
grep -Fx "RUST_TOOLCHAIN=$rust_toolchain" "$scratch/environment"

source_revision=$(git -C "$repo_root" rev-parse HEAD)
git clone --quiet --shared --no-checkout "$repo_root" "$scratch/repository"
git -C "$scratch/repository" checkout --quiet --detach "$source_revision"
jq '.zig.version = "0.17.0-dev.9999+aaaaaaaaa"' \
  "$scratch/repository/tools/development-targets.json" >"$scratch/candidate.json"
(
  cd "$scratch/repository"
  tools/apply-development-target.sh zig "$scratch/candidate.json"
  mkdir -p evidence
  printf '%s\n' transient >candidate.json
  printf '%s\n' transient >evidence/classification.json
  git add --update
  if git diff --cached --name-only | grep -E '^(\.github/workflows/|candidate\.json$|evidence/)'; then
    echo "candidate staging included a workflow or transient artifact" >&2
    exit 1
  fi
  git diff --cached --quiet && {
    echo "candidate staging produced no tracked update" >&2
    exit 1
  }
  true
)

echo "development target lifecycle integration passed"
