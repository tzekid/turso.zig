#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "release input rejected: $*" >&2
  exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=$repo_root
upstream_root=
skip_tree_state=false
skip_ref=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      source_root=${2:?--source-root requires a path}
      shift 2
      ;;
    --upstream-root)
      upstream_root=${2:?--upstream-root requires a path}
      shift 2
      ;;
    --skip-tree-state)
      skip_tree_state=true
      shift
      ;;
    --skip-ref)
      skip_ref=true
      shift
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

source_root=$(cd "$source_root" && pwd)
version_file="$source_root/src/version.zig"
zon_file="$source_root/build.zig.zon"
[[ -f $version_file && -f $zon_file ]] || fail "package version files are missing"

zig_version=$(
  sed -n -E 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$zon_file" |
    head -1
)
binding_version=$(
  sed -n -E 's/^pub const binding(:[^=]+)? = "([^"]+)";/\2/p' "$version_file" |
    head -1
)
turso_version=$(
  sed -n -E 's/^pub const upstream(:[^=]+)? = "([^"]+)";/\2/p' "$version_file" |
    head -1
)
turso_commit=$(
  sed -n -E 's/^pub const upstream_commit(:[^=]+)? = "([^"]+)";/\2/p' "$version_file" |
    head -1
)
turso_tag=$(
  sed -n -E 's/^pub const upstream_tag(:[^=]+)? = "([^"]+)";/\2/p' "$version_file" |
    head -1
)
turso_tag_object=$(
  sed -n -E 's/^pub const upstream_tag_object(:[^=]+)? = "([^"]+)";/\2/p' "$version_file" |
    head -1
)

[[ $binding_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "binding version is not a stable semantic version: ${binding_version:-missing}"
[[ $zig_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Zig must be stable; got ${zig_version:-missing}"
[[ $turso_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Turso must be stable; got ${turso_version:-missing}"
[[ $turso_commit =~ ^[0-9a-f]{40}$ ]] ||
  fail "Turso commit is missing or not immutable"
[[ -n $turso_tag ]] || fail "Turso stable tag provenance is missing"
[[ -n $turso_tag_object ]] || fail "Turso annotated tag object provenance is missing"

if [[ -n $upstream_root ]]; then
  upstream_root=$(cd "$upstream_root" && pwd)
  actual_tag_object=$(git -C "$upstream_root" rev-parse "$turso_tag^{tag}" 2>/dev/null) ||
    fail "Turso tag is not annotated: $turso_tag"
  actual_commit=$(git -C "$upstream_root" rev-parse "$turso_tag^{commit}" 2>/dev/null) ||
    fail "Turso tag does not peel to a commit: $turso_tag"
  [[ $actual_tag_object == "$turso_tag_object" ]] || fail "Turso tag object does not match"
  [[ $actual_commit == "$turso_commit" ]] || fail "Turso tag does not peel to the recorded commit"
fi

if [[ $skip_tree_state == false ]]; then
  [[ -z $(git -C "$source_root" status --porcelain --untracked-files=all) ]] ||
    fail "source checkout is dirty"
fi

if [[ $skip_ref == false ]]; then
  branch=$(git -C "$source_root" symbolic-ref --quiet --short HEAD || true)
  exact_tag=$(git -C "$source_root" describe --exact-match --tags HEAD 2>/dev/null || true)
  stable_ref=$(
    git -C "$source_root" branch --all --contains HEAD --format='%(refname:short)' |
      grep -E '(^|/)v[0-9]+\.[0-9]+\.[0-9]+-stable$' |
      head -1 ||
      true
  )
  expected_tag="v$binding_version"
  if [[ ! $branch =~ ^v[0-9]+\.[0-9]+\.[0-9]+-stable$ &&
    -z $stable_ref && $exact_tag != "$expected_tag" ]]; then
    fail "run from a stable branch or the exact release tag $expected_tag; current branch is ${branch:-detached}"
  fi
fi

if [[ -f "$source_root/tools/development-targets.json" ]]; then
  "$source_root/tools/check-development-targets.sh" >/dev/null ||
    fail "target manifest copies disagree"
fi

echo "stable release inputs accepted"
