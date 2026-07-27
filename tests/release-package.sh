#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
upstream_root=${UPSTREAM_ROOT:-}
static_library=${STATIC_LIBRARY:-}
dynamic_library=${DYNAMIC_LIBRARY:-}
import_library=${IMPORT_LIBRARY:-}
static_deps=${STATIC_DEPS:-}
dynamic_deps=${DYNAMIC_DEPS:-}
ci_run_url=${CI_RUN_URL:-https://github.com/tzekid/turso.zig/actions/runs/1}
target=${TARGET:-x86_64-unknown-linux-gnu}
cpu_baseline=${CPU_BASELINE:-x86-64-v1}
minimum_platform=${MINIMUM_PLATFORM:-ubuntu-24.04 glibc>=2.35}
work_root=${WORK_ROOT:-}
keep_work=false
skip_source=false
sync=false

usage() {
    cat <<'EOF'
usage: tests/release-package.sh --static FILE --dynamic FILE [options]

Options:
  --upstream-root DIR   pinned-tag-capable Turso checkout
  --work-root DIR       explicit test scratch root (default: mktemp)
  --keep-work           retain a default temporary root
  --static-deps FILE    target-native native-static-libs evidence
  --dynamic-deps FILE   target-native dynamic dependency evidence
  --import-library FILE Windows dynamic import library
  --skip-source         skip source archive assembly/smoke in native-only lanes
  --sync                package and smoke the sync SDK Kit variant
  --ci-run-url URL      immutable CI run URL recorded in manifests
  --target TRIPLE       Linux Rust target triple
  --cpu-baseline TEXT   native package CPU baseline
  --minimum-platform TEXT native package OS/libc floor

The test creates an exact detached checkout outside the repository, proves
source-commit provenance, deterministic archives, and dirty-tree refusal, then
packages and smokes the supplied target-native ReleaseSafe artifacts.
EOF
}

while (($#)); do
    case "$1" in
        --upstream-root) upstream_root=${2:?}; shift 2 ;;
        --static) static_library=${2:?}; shift 2 ;;
        --dynamic) dynamic_library=${2:?}; shift 2 ;;
        --static-deps) static_deps=${2:?}; shift 2 ;;
        --dynamic-deps) dynamic_deps=${2:?}; shift 2 ;;
        --import-library) import_library=${2:?}; shift 2 ;;
        --skip-source) skip_source=true; shift ;;
        --sync) sync=true; shift ;;
        --ci-run-url) ci_run_url=${2:?}; shift 2 ;;
        --target) target=${2:?}; shift 2 ;;
        --cpu-baseline) cpu_baseline=${2:?}; shift 2 ;;
        --minimum-platform) minimum_platform=${2:?}; shift 2 ;;
        --work-root) work_root=${2:?}; shift 2 ;;
        --keep-work) keep_work=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ -f "$static_library" ]] || { echo "static library is required" >&2; exit 64; }
[[ -f "$dynamic_library" ]] || { echo "dynamic library is required" >&2; exit 64; }
[[ -d "$upstream_root" ]] || { echo "upstream Turso checkout is required" >&2; exit 64; }
static_library=$(realpath "$static_library")
dynamic_library=$(realpath "$dynamic_library")
if [[ -n "$import_library" ]]; then import_library=$(realpath "$import_library"); fi
upstream_root=$(realpath "$upstream_root")

made_temp=false
if [[ -z "$work_root" ]]; then
    work_root=$(mktemp -d "${TMPDIR:-/tmp}/turso-release-test.XXXXXX")
    made_temp=true
else
    mkdir -p -- "$work_root"
    work_root=$(realpath "$work_root")
fi

cleanup() {
    if $made_temp && ! $keep_work; then rm -rf -- "$work_root"; fi
}
trap cleanup EXIT

source_root="$work_root/source checkout"
git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1 ||
    { echo "repository root must have a committed HEAD" >&2; exit 64; }
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] ||
    { echo "repository root must be clean for release integration" >&2; exit 64; }
source_commit=$(git -C "$repo_root" rev-parse HEAD)
git clone --no-hardlinks --no-checkout --quiet "$repo_root" "$source_root"
git -C "$source_root" checkout --quiet --detach "$source_commit"
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$source_commit" ]] ||
    { echo "release checkout did not preserve the source commit" >&2; exit 1; }
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]] ||
    { echo "release checkout is unexpectedly dirty" >&2; exit 1; }

package="$source_root/tools/package-release.sh"
smoke="$source_root/tools/smoke-release.sh"
chmod 0755 "$package" "$smoke"

sdk_name=turso_sdk_kit
features=encryption,pure-rust-crypto
if $sync; then
    sdk_name=turso_sync_sdk_kit
    features=pure-rust-crypto
fi

mkdir -p "$work_root/evidence"
if [[ -n "$static_deps" ]]; then
    cp -- "$(realpath "$static_deps")" "$work_root/evidence/native-static-libs.txt"
else
cat >"$work_root/evidence/native-static-libs.txt" <<EOF
command=cargo rustc -p $sdk_name --lib --locked -- --print native-static-libs
target=$target
output=-ldl -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
EOF
fi
if [[ -n "$dynamic_deps" ]]; then
    cp -- "$(realpath "$dynamic_deps")" "$work_root/evidence/native-dynamic-deps.txt"
else
cat >"$work_root/evidence/native-dynamic-deps.txt" <<EOF
command=readelf -d lib${sdk_name}.so
target=$target
required=libgcc_s.so.1,libm.so.6,libc.so.6,ld-linux-x86-64.so.2
EOF
fi

common=(
    --source-root "$source_root"
    --upstream-root "$upstream_root"
    --features "$features"
    --optimize ReleaseSafe
    --ci-run-url "$ci_run_url"
)
if $sync; then common+=(--sync); fi
native_metadata=(
    --cpu-baseline "$cpu_baseline"
    --minimum-platform "$minimum_platform"
)

if ! $skip_source; then
    mkdir -p "$work_root/stage source 1" "$work_root/stage source 2" "$work_root/out source 1" "$work_root/out source 2"
    "$package" source "${common[@]}" --stage-root "$work_root/stage source 1" --output-dir "$work_root/out source 1"
    "$package" source "${common[@]}" --stage-root "$work_root/stage source 2" --output-dir "$work_root/out source 2"
    source_archive_1=$(find "$work_root/out source 1" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
    source_archive_2=$(find "$work_root/out source 2" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
    source_manifest=$(find "$work_root/stage source 1" -type f -name manifest.json -print -quit)
    jq -e --arg source_commit "$source_commit" \
        '.package.source_commit == $source_commit' "$source_manifest" >/dev/null
    cmp "$source_archive_1" "$source_archive_2"
    "$smoke" --archive "$source_archive_1" --work-root "$work_root/smoke source"

    printf 'dirty\n' >"$source_root/release-dirty-sentinel"
    if "$package" source "${common[@]}" --stage-root "$work_root/stage-dirty" --output-dir "$work_root/out-dirty" >"$work_root/dirty.log" 2>&1; then
        echo "packager accepted a dirty source checkout" >&2
        exit 1
    fi
    rm -f "$source_root/release-dirty-sentinel"
fi

mkdir -p "$work_root/stage static" "$work_root/out static"
"$package" native "${common[@]}" \
    "${native_metadata[@]}" \
    --stage-root "$work_root/stage static" \
    --output-dir "$work_root/out static" \
    --target "$target" \
    --linkage static \
    --native-library "$static_library" \
    --native-deps "$work_root/evidence/native-static-libs.txt"
static_manifest=$(find "$work_root/stage static" -type f -name manifest.json -print -quit)
static_size=$(wc -c < "$static_library" | tr -d '[:space:]')
jq -e \
    --argjson size "$static_size" \
    --argjson sync "$sync" \
    --arg sdk_name "$sdk_name" \
    --arg source_commit "$source_commit" \
    '.native.size_bytes == $size and
     .build.sync_enabled == $sync and
     .native.library_name == $sdk_name and
     .package.source_commit == $source_commit and
     .abi.variant == (if $sync then "sync" else "base" end)' \
    "$static_manifest" >/dev/null
static_archive=$(find "$work_root/out static" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
mkdir -p "$work_root/stage static 2" "$work_root/out static 2"
"$package" native "${common[@]}" \
    "${native_metadata[@]}" \
    --stage-root "$work_root/stage static 2" \
    --output-dir "$work_root/out static 2" \
    --target "$target" \
    --linkage static \
    --native-library "$static_library" \
    --native-deps "$work_root/evidence/native-static-libs.txt"
static_archive_2=$(find "$work_root/out static 2" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
cmp "$static_archive" "$static_archive_2"
"$smoke" --archive "$static_archive" --work-root "$work_root/smoke static"

mkdir -p "$work_root/stage dynamic" "$work_root/out dynamic"
dynamic_command=(
    "$package" native "${common[@]}"
    "${native_metadata[@]}"
    --stage-root "$work_root/stage dynamic"
    --output-dir "$work_root/out dynamic"
    --target "$target"
    --linkage dynamic
    --native-library "$dynamic_library"
)
if [[ -n "$import_library" ]]; then
    dynamic_command+=(--import-library "$import_library")
fi
dynamic_command+=(
    --native-deps "$work_root/evidence/native-dynamic-deps.txt"
)
"${dynamic_command[@]}"
dynamic_archive=$(find "$work_root/out dynamic" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
dynamic_manifest=$(find "$work_root/stage dynamic" -type f -name manifest.json -print -quit)
jq -e --arg source_commit "$source_commit" \
    '.package.source_commit == $source_commit' "$dynamic_manifest" >/dev/null
"$smoke" --archive "$dynamic_archive" --work-root "$work_root/smoke dynamic"

cp "$static_archive.sha256" "$work_root/bad.sha256"
first_char=$(cut -c1 "$work_root/bad.sha256")
if [[ "$first_char" == 0 ]]; then replacement=1; else replacement=0; fi
sed -i.bak "s/^./$replacement/" "$work_root/bad.sha256"
rm -f "$work_root/bad.sha256.bak"
if "$smoke" --archive "$static_archive" --sidecar "$work_root/bad.sha256" --work-root "$work_root/smoke-bad" --skip-consumer >"$work_root/bad-checksum.log" 2>&1; then
    echo "release smoke accepted a bad archive checksum" >&2
    exit 1
fi

echo "release package integration OK: $work_root"
