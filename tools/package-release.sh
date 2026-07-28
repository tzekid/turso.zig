#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
default_source_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)

kind=
source_root=$default_source_root
upstream_root=
stage_root=
output_dir=
target=source
linkage=none
features=
optimize=ReleaseSafe
sync=false
native_library=
import_library=
native_deps=
zig_version=
rust_version=
cargo_version=
ci_run_url=
cpu_baseline=
minimum_platform=

usage() {
    cat <<'EOF'
usage: tools/package-release.sh source|native OPTIONS

Required for every package:
  --source-root DIR       clean git checkout of turso.zig
  --upstream-root DIR     clean Turso git checkout containing the pinned tag
  --stage-root DIR        explicit scratch root, outside both checkouts
  --output-dir DIR        archive destination, outside both checkouts

Required for a native package:
  --target TRIPLE         target identity recorded in the manifest
  --linkage MODE          static or dynamic
  --native-library FILE   .a/.lib, .so/.dylib, or runtime .dll
  --native-deps FILE      non-empty target-native dependency evidence

Windows dynamic packages also require --import-library FILE. Optional:
  --sync                  package the sync SDK Kit variant
  --features LIST         comma-separated Cargo features
  --optimize MODE         defaults to ReleaseSafe
  --zig-version TEXT      producer version; defaults to `zig version`
  --rust-version TEXT     producer version; defaults to `rustc -V`
  --cargo-version TEXT    producer version; defaults to `cargo -V`
  --ci-run-url URL        required immutable GitHub Actions run URL

Native packages additionally require:
  --cpu-baseline TEXT     declared CPU feature baseline
  --minimum-platform TEXT minimum supported OS/libc deployment target

The command refuses dirty trees, inconsistent provenance, ABI drift, target or
file mismatches, embedded checkout/cache paths, and incomplete dynamic inputs.
It writes a deterministic .tar.gz plus a .sha256 sidecar; it never publishes.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 64; }
kind=$1
shift
[[ "$kind" == source || "$kind" == native ]] || { echo "kind must be source or native" >&2; exit 64; }

while (($#)); do
    case "$1" in
        --source-root) source_root=${2:?}; shift 2 ;;
        --upstream-root) upstream_root=${2:?}; shift 2 ;;
        --stage-root) stage_root=${2:?}; shift 2 ;;
        --output-dir) output_dir=${2:?}; shift 2 ;;
        --target) target=${2:?}; shift 2 ;;
        --linkage) linkage=${2:?}; shift 2 ;;
        --sync) sync=true; shift ;;
        --features) features=${2:?}; shift 2 ;;
        --optimize) optimize=${2:?}; shift 2 ;;
        --native-library) native_library=${2:?}; shift 2 ;;
        --import-library) import_library=${2:?}; shift 2 ;;
        --native-deps) native_deps=${2:?}; shift 2 ;;
        --zig-version) zig_version=${2:?}; shift 2 ;;
        --rust-version) rust_version=${2:?}; shift 2 ;;
        --cargo-version) cargo_version=${2:?}; shift 2 ;;
        --ci-run-url) ci_run_url=${2:?}; shift 2 ;;
        --cpu-baseline) cpu_baseline=${2:?}; shift 2 ;;
        --minimum-platform) minimum_platform=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

fail() {
    echo "package-release: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

canonical_dir() {
    [[ -d "$1" ]] || fail "directory not found: $1"
    CDPATH='' cd -- "$1" && pwd -P
}

path_is_within() {
    case "$1/" in
        "$2/"*) return 0 ;;
        *) return 1 ;;
    esac
}

extract_zig_string() {
    local file=$1
    local name=$2
    sed -n -E "s/^[[:space:]]*pub const ${name}[[:space:]]*=[[:space:]]*\"([^\"]+)\";.*/\1/p" "$file"
}

extract_zon_version() {
    sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$1" | head -1
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

reject_path_leaks() {
    local input=$1
    local description=$2
    local pattern='\.zig-cache|(^|[/\\])zig-pkg([/\\]|$)|cargo-target|[/\\]\.cargo[/\\]registry'
    local escaped_source escaped_upstream escaped_stage leak
    escaped_source=$(printf '%s' "$source_root" | sed 's/[][\.^$*+?{}|()]/\\&/g')
    escaped_upstream=$(printf '%s' "$upstream_root" | sed 's/[][\.^$*+?{}|()]/\\&/g')
    escaped_stage=$(printf '%s' "$stage_root" | sed 's/[][\.^$*+?{}|()]/\\&/g')
    leak=$(strings -a "$input" |
        LC_ALL=C grep -E "$pattern|$escaped_source|$escaped_upstream|$escaped_stage" |
        sed -n '1p' || true)
    if [[ -n "$leak" ]]; then
        leak=${leak//"$source_root"/<source-root>}
        leak=${leak//"$upstream_root"/<upstream-root>}
        leak=${leak//"$stage_root"/<stage-root>}
        printf 'package-release: rejected embedded path: %s\n' "$leak" >&2
        fail "$description contains a checkout, Cargo registry, or build-cache path"
    fi
}

native_identity() {
    local library=$1
    local description
    description=$(file -b "$library")
    case "$library" in
        *.a|*.lib)
            require_command ar
            local member member_file member_description
            member=$(ar t "$library" | grep -E '\.(o|obj)$' | sed -n '1p' || true)
            [[ -n "$member" ]] || fail "cannot find an object member in static library: $library"
            member_file=$(mktemp "${TMPDIR:-/tmp}/turso-native-member.XXXXXX")
            if ! ar p "$library" "$member" >"$member_file"; then
                rm -f -- "$member_file"
                fail "cannot extract object member from static library: $library"
            fi
            if ! member_description=$(file -b "$member_file"); then
                rm -f -- "$member_file"
                fail "cannot identify object member from static library: $library"
            fi
            rm -f -- "$member_file"
            description="$description; $member_description"
            ;;
    esac
    printf '%s\n' "$description"
}

validate_native_identity() {
    local identity=$1
    case "$target" in
        *linux*) [[ "$identity" == *ELF* ]] || fail "native library is not ELF for target $target: $identity" ;;
        *macos*|*darwin*) [[ "$identity" == *Mach-O* ]] || fail "native library is not Mach-O for target $target: $identity" ;;
        *windows*) [[ "$identity" == *PE32* || "$identity" == *COFF* || "$identity" == *Microsoft* ]] || fail "native library is not PE/COFF for target $target: $identity" ;;
        *) fail "unsupported native release target: $target" ;;
    esac
    case "$target" in
        *x86_64*) [[ "$identity" =~ x86-64|x86_64|AMD64 ]] || fail "native architecture does not match x86_64 target: $identity" ;;
        *aarch64*|*arm64*) [[ "$identity" =~ Aarch64|aarch64|arm64|ARM64 ]] || fail "native architecture does not match aarch64 target: $identity" ;;
        *) fail "unsupported native release architecture: $target" ;;
    esac
}

require_command git
require_command jq
require_command sha256sum
require_command strings
require_command file
require_command tar
require_command gzip
require_command realpath

tar --version 2>/dev/null | head -1 | grep -q 'GNU tar' || fail "deterministic packaging currently requires GNU tar"

[[ -n "$upstream_root" ]] || fail "--upstream-root is required"
[[ -n "$stage_root" ]] || fail "--stage-root is required"
[[ -n "$output_dir" ]] || fail "--output-dir is required"

source_root=$(canonical_dir "$source_root")
upstream_root=$(canonical_dir "$upstream_root")
mkdir -p -- "$stage_root" "$output_dir"
stage_root=$(canonical_dir "$stage_root")
output_dir=$(canonical_dir "$output_dir")

path_is_within "$stage_root" "$source_root" && fail "stage root must be outside the source checkout"
path_is_within "$output_dir" "$source_root" && fail "output directory must be outside the source checkout"
path_is_within "$stage_root" "$upstream_root" && fail "stage root must be outside the upstream checkout"
path_is_within "$output_dir" "$upstream_root" && fail "output directory must be outside the upstream checkout"
[[ "$stage_root" != "$output_dir" ]] || fail "stage root and output directory must differ"

git -C "$source_root" rev-parse --verify HEAD >/dev/null 2>&1 || fail "source root must have a committed HEAD"
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]] || fail "source checkout is dirty"
git -C "$upstream_root" rev-parse --verify HEAD >/dev/null 2>&1 || fail "upstream root must be a git checkout"
[[ -z "$(git -C "$upstream_root" status --porcelain --untracked-files=all)" ]] || fail "upstream checkout is dirty"

for path in build.zig build.zig.zon LICENSE NOTICE README.md include/turso.h src/version.zig tools/check-abi-symbols.sh tests/expected-base-symbols.txt tests/consumer/build.zig tests/consumer/build.zig.zon tests/consumer/src/main.zig; do
    [[ -f "$source_root/$path" ]] || fail "required source file is missing: $path"
done
if $sync; then
    for path in include/turso_sync.h tests/expected-sync-symbols.txt src/sync.zig; do
        [[ -f "$source_root/$path" ]] || fail "required sync source file is missing: $path"
    done
fi

binding_version=$(extract_zig_string "$source_root/src/version.zig" binding)
zon_version=$(extract_zon_version "$source_root/build.zig.zon")
[[ -n "$binding_version" && "$binding_version" == "$zon_version" ]] || fail "binding version disagrees between version.zig and build.zig.zon"
upstream_version=$(extract_zig_string "$source_root/src/version.zig" upstream)
upstream_tag=$(extract_zig_string "$source_root/src/version.zig" upstream_tag)
upstream_commit=$(extract_zig_string "$source_root/src/version.zig" upstream_commit)
upstream_tag_object=$(extract_zig_string "$source_root/src/version.zig" upstream_tag_object)
header_sha=$(extract_zig_string "$source_root/src/version.zig" upstream_header_sha256)
[[ -n "$upstream_version" && -n "$upstream_tag" && -n "$upstream_commit" && -n "$upstream_tag_object" && -n "$header_sha" ]] || fail "version.zig provenance is incomplete"
sync_header_sha=
if $sync; then
    sync_header_sha=$(extract_zig_string "$source_root/src/version.zig" upstream_sync_header_sha256)
    [[ -n "$sync_header_sha" ]] || fail "version.zig sync header provenance is incomplete"
fi

actual_tag_object=$(git -C "$upstream_root" rev-parse "$upstream_tag^{tag}" 2>/dev/null) || fail "upstream annotated tag is missing: $upstream_tag"
actual_commit=$(git -C "$upstream_root" rev-parse "$upstream_tag^{commit}")
[[ "$actual_tag_object" == "$upstream_tag_object" ]] || fail "upstream tag object mismatch"
[[ "$actual_commit" == "$upstream_commit" ]] || fail "upstream peeled commit mismatch"

upstream_header_tmp=$(mktemp "${TMPDIR:-/tmp}/turso-header.XXXXXX")
trap 'rm -f "$upstream_header_tmp"' EXIT
git -C "$upstream_root" show "$upstream_tag:sdk-kit/turso.h" >"$upstream_header_tmp"
[[ "$(sha256_file "$upstream_header_tmp")" == "$header_sha" ]] || fail "upstream header digest mismatch"
vendored_header_sha=$(sed -n '/^#ifndef TURSO_H/,$p' "$source_root/include/turso.h" | sha256sum | awk '{print $1}')
[[ "$vendored_header_sha" == "$header_sha" ]] || fail "vendored header body differs from upstream"
if $sync; then
    upstream_sync_header_tmp=$(mktemp "${TMPDIR:-/tmp}/turso-sync-header.XXXXXX")
    trap 'rm -f "$upstream_header_tmp" "$upstream_sync_header_tmp"' EXIT
    git -C "$upstream_root" show "$upstream_tag:sync/sdk-kit/turso_sync.h" >"$upstream_sync_header_tmp"
    [[ "$(sha256_file "$upstream_sync_header_tmp")" == "$sync_header_sha" ]] || fail "upstream sync header digest mismatch"
    vendored_sync_header_sha=$(sed -n '/^#ifndef TURSO_SYNC_H/,$p' "$source_root/include/turso_sync.h" | sha256sum | awk '{print $1}')
    [[ "$vendored_sync_header_sha" == "$sync_header_sha" ]] || fail "vendored sync header body differs from upstream"
fi
grep -F "$upstream_commit" "$source_root/NOTICE" >/dev/null || fail "NOTICE lacks the peeled upstream commit"
grep -F "$header_sha" "$source_root/NOTICE" >/dev/null || fail "NOTICE lacks the upstream header digest"

source_commit=$(git -C "$source_root" rev-parse HEAD)
fingerprint=$(sed -n -E 's/^[[:space:]]*\.fingerprint[[:space:]]*=[[:space:]]*([^,]+),.*/\1/p' "$source_root/build.zig.zon" | head -1)
package_hash=$(sed -n -E 's/^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$source_root/build.zig.zon" | head -1)
source_epoch=1784727869
[[ -n "$fingerprint" && -n "$package_hash" ]] || fail "package fingerprint or upstream package hash is missing"

if [[ -z "$features" ]]; then
    features=$(if $sync; then printf '%s' pure-rust-crypto; else printf '%s' encryption,pure-rust-crypto; fi)
fi
[[ "$features" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || fail "features must be a non-empty comma-separated token list"
if $sync && [[ "$features" != pure-rust-crypto ]]; then
    fail "sync packages require the exact source-build feature set: pure-rust-crypto"
fi
[[ "$optimize" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid optimization name"
[[ "$optimize" == ReleaseSafe ]] || fail "release archives require --optimize ReleaseSafe"
[[ "$ci_run_url" =~ ^https://github\.com/[^/]+/[^/]+/actions/runs/[0-9]+([/?#].*)?$ ]] ||
    fail "--ci-run-url must be an immutable GitHub Actions run URL"

if [[ -z "$zig_version" ]]; then require_command zig; zig_version=$(zig version); fi
if [[ -z "$rust_version" ]]; then require_command rustc; rust_version=$(rustc -V); fi
if [[ -z "$cargo_version" ]]; then require_command cargo; cargo_version=$(cargo -V); fi
[[ "$zig_version" == 0.16.0 ]] || fail "release requires Zig 0.16.0, got: $zig_version"

native_path=
native_sha=
native_size=0
native_identity_text=
native_deps_sha=
import_path=
import_sha=
native_name=turso_sdk_kit
abi_symbol_count=48
abi_args=(
    --header "$source_root/include/turso.h"
    --expected "$source_root/tests/expected-base-symbols.txt"
)
if $sync; then
    native_name=turso_sync_sdk_kit
    abi_symbol_count=77
    abi_args+=(
        --sync
        --sync-header "$source_root/include/turso_sync.h"
        --sync-expected "$source_root/tests/expected-sync-symbols.txt"
    )
fi

if [[ "$kind" == source ]]; then
    [[ "$target" == source && "$linkage" == none ]] || fail "source packages use target=source and linkage=none"
    [[ -z "$native_library$import_library$native_deps" ]] || fail "source packages do not accept native artifact options"
    [[ -z "$cpu_baseline$minimum_platform" ]] || fail "CPU/platform metadata is only valid for native packages"
else
    [[ "$target" =~ ^[A-Za-z0-9._+-]+$ && "$target" != source ]] || fail "--target is required for native packages"
    [[ "$linkage" == static || "$linkage" == dynamic ]] || fail "native linkage must be static or dynamic"
    [[ -f "$native_library" ]] || fail "native library not found: $native_library"
    [[ -s "$native_deps" ]] || fail "--native-deps must name a non-empty evidence file"
    [[ -n "$cpu_baseline" ]] || fail "--cpu-baseline is required for native packages"
    [[ -n "$minimum_platform" ]] || fail "--minimum-platform is required for native packages"
    case "$target" in
        x86_64-unknown-linux-gnu)
            [[ "$cpu_baseline" == x86-64-v1 ]] || fail "x86_64 Linux packages require cpu baseline x86-64-v1"
            [[ "$minimum_platform" =~ ^ubuntu-24\.04[[:space:]]glibc\>\=2\.[0-9]+$ ]] || fail "x86_64 Linux minimum platform must include the audited glibc floor"
            ;;
        aarch64-unknown-linux-gnu)
            [[ "$cpu_baseline" == armv8-a ]] || fail "aarch64 Linux packages require cpu baseline armv8-a"
            [[ "$minimum_platform" =~ ^ubuntu-24\.04[[:space:]]glibc\>\=2\.[0-9]+$ ]] || fail "aarch64 Linux minimum platform must include the audited glibc floor"
            ;;
        x86_64-unknown-linux-musl)
            [[ "$cpu_baseline" == x86-64-v1 ]] || fail "x86_64 musl packages require cpu baseline x86-64-v1"
            [[ "$minimum_platform" =~ ^alpine-3\.22[[:space:]]musl\>\=1\.2\.5$ ]] || fail "x86_64 musl packages require the audited Alpine/musl floor"
            ;;
        aarch64-unknown-linux-musl)
            [[ "$cpu_baseline" == armv8-a ]] || fail "aarch64 musl packages require cpu baseline armv8-a"
            [[ "$minimum_platform" =~ ^alpine-3\.22[[:space:]]musl\>\=1\.2\.5$ ]] || fail "aarch64 musl packages require the audited Alpine/musl floor"
            ;;
        x86_64-apple-darwin)
            [[ "$cpu_baseline" == x86-64-v1 ]] || fail "x86_64 Darwin packages require cpu baseline x86-64-v1"
            [[ "$minimum_platform" =~ ^macOS-[0-9]+([.][0-9]+)*$ ]] || fail "Darwin packages require an explicit macOS deployment floor"
            ;;
        aarch64-apple-darwin)
            [[ "$cpu_baseline" == armv8-a ]] || fail "aarch64 Darwin packages require cpu baseline armv8-a"
            [[ "$minimum_platform" =~ ^macOS-[0-9]+([.][0-9]+)*$ ]] || fail "Darwin packages require an explicit macOS deployment floor"
            ;;
        x86_64-pc-windows-msvc)
            [[ "$cpu_baseline" == x86-64-v1 ]] || fail "x86_64 Windows packages require cpu baseline x86-64-v1"
            [[ "$minimum_platform" =~ ^Windows-[0-9]+([.][0-9]+)*$ ]] || fail "Windows packages require an explicit Windows deployment floor"
            ;;
        aarch64-pc-windows-msvc)
            [[ "$cpu_baseline" == armv8-a ]] || fail "aarch64 Windows packages require cpu baseline armv8-a"
            [[ "$minimum_platform" =~ ^Windows-[0-9]+([.][0-9]+)*$ ]] || fail "Windows packages require an explicit Windows deployment floor"
            ;;
        *) fail "unsupported release target policy: $target" ;;
    esac
    native_library=$(realpath "$native_library")
    native_deps=$(realpath "$native_deps")
    grep -Fx "target=$target" "$native_deps" >/dev/null ||
        fail "dependency evidence target does not match --target"
    if [[ "$linkage" == static ]]; then
        grep -F 'native-static-libs' "$native_deps" >/dev/null ||
            fail "static dependency evidence must identify native-static-libs"
        grep -E "^command=.*-p[[:space:]]+$native_name([[:space:]]|$)" "$native_deps" >/dev/null ||
            fail "static dependency evidence names the wrong SDK Kit variant"
        grep -E '^output=.+$' "$native_deps" >/dev/null ||
            fail "static dependency evidence must contain a non-empty output"
    else
        grep -E '^command=(readelf|otool|llvm-readobj|dumpbin)([[:space:]]|$)' "$native_deps" >/dev/null ||
            fail "dynamic dependency evidence must identify the target-native inspection command"
        grep -E "^command=.*$native_name" "$native_deps" >/dev/null ||
            fail "dynamic dependency evidence names the wrong SDK Kit variant"
        grep -E '^required=.+$' "$native_deps" >/dev/null ||
            fail "dynamic dependency evidence must contain a non-empty required set"
        case "$target" in
            *apple-darwin)
                grep -Fx "install_name=@rpath/lib$native_name.dylib" "$native_deps" >/dev/null ||
                    fail "Darwin dependency evidence must contain the portable dylib install name"
                ;;
        esac
    fi

    native_basename=$(basename "$native_library")
    case "$target:$linkage:$native_basename" in
        *linux*:static:"lib$native_name.a") native_path="lib/$native_basename" ;;
        *linux*:dynamic:"lib$native_name.so") native_path="lib/$native_basename" ;;
        *macos*:static:"lib$native_name.a"|*darwin*:static:"lib$native_name.a") native_path="lib/$native_basename" ;;
        *macos*:dynamic:"lib$native_name.dylib"|*darwin*:dynamic:"lib$native_name.dylib") native_path="lib/$native_basename" ;;
        *windows*:static:"$native_name.lib") native_path="lib/$native_basename" ;;
        *windows*:dynamic:"$native_name.dll") native_path="bin/$native_basename" ;;
        *) fail "native filename does not match selected SDK Kit variant/target/linkage: $target $linkage $native_basename" ;;
    esac

    if [[ "$target" == *windows* && "$linkage" == dynamic ]]; then
        [[ -f "$import_library" && "$(basename "$import_library")" == "$native_name.dll.lib" ]] ||
            fail "Windows dynamic packages require the selected SDK Kit import library: $native_name.dll.lib"
        import_library=$(realpath "$import_library")
        import_path="lib/$(basename "$import_library")"
        import_sha=$(sha256_file "$import_library")
    else
        [[ -z "$import_library" ]] || fail "--import-library is only valid for Windows dynamic packages"
    fi

    "$source_root/tools/check-abi-symbols.sh" "${abi_args[@]}" "$native_library"
    native_identity_text=$(native_identity "$native_library")
    validate_native_identity "$native_identity_text"
    reject_path_leaks "$native_library" "native library"
    if [[ -n "$import_library" ]]; then reject_path_leaks "$import_library" "native import library"; fi
    reject_path_leaks "$native_deps" "native dependency evidence"
    native_sha=$(sha256_file "$native_library")
    native_size=$(wc -c < "$native_library" | tr -d '[:space:]')
    native_deps_sha=$(sha256_file "$native_deps")
fi

features_slug=${features//,/-}
if [[ "$kind" == source ]]; then
    if $sync; then
        package_name="turso-zig-$binding_version-source-sync"
    else
        package_name="turso-zig-$binding_version-source"
    fi
else
    if $sync; then
        package_name="turso-zig-$binding_version-$target-$linkage-sync-$features_slug"
    else
        package_name="turso-zig-$binding_version-$target-$linkage-$features_slug"
    fi
fi
package_root="$stage_root/$package_name"
archive="$output_dir/$package_name.tar.gz"
sidecar="$archive.sha256"

rm -rf -- "$package_root"
mkdir -p -- "$package_root"

while IFS= read -r -d '' tracked; do
    [[ "$tracked" != /* && "$tracked" != ../* && "$tracked" != *'/../'* ]] || fail "unsafe tracked path: $tracked"
    mkdir -p -- "$package_root/$(dirname -- "$tracked")"
    cp -P -- "$source_root/$tracked" "$package_root/$tracked"
done < <(git -C "$source_root" ls-files -z)

# A release archive is one SDK Kit variant. The base archive cannot silently
# become sync-capable merely because the repository also tracks sync inputs.
if ! $sync; then
    rm -f -- "$package_root/include/turso_sync.h" "$package_root/tests/expected-sync-symbols.txt"
fi

mkdir -p -- "$package_root/licenses/turso" "$package_root/evidence"
git -C "$upstream_root" show "$upstream_tag:LICENSE.md" >"$package_root/licenses/turso/LICENSE.md"
git -C "$upstream_root" show "$upstream_tag:NOTICE.md" >"$package_root/licenses/turso/NOTICE.md"
[[ -s "$package_root/licenses/turso/LICENSE.md" && -s "$package_root/licenses/turso/NOTICE.md" ]] || fail "upstream license or notice is empty"
wrapper_license_sha=$(sha256_file "$package_root/LICENSE")
wrapper_notice_sha=$(sha256_file "$package_root/NOTICE")
upstream_license_sha=$(sha256_file "$package_root/licenses/turso/LICENSE.md")
upstream_notice_sha=$(sha256_file "$package_root/licenses/turso/NOTICE.md")

if [[ "$kind" == native ]]; then
    mkdir -p -- "$package_root/$(dirname -- "$native_path")"
    cp -- "$native_library" "$package_root/$native_path"
    cp -- "$native_deps" "$package_root/evidence/native-dependencies.txt"
    printf '%s\n' "$native_identity_text" >"$package_root/evidence/native-identity.txt"
    if [[ -n "$import_library" ]]; then
        mkdir -p -- "$package_root/$(dirname -- "$import_path")"
        cp -- "$import_library" "$package_root/$import_path"
    fi
fi

jq -n -S \
    --arg package_version "$binding_version" \
    --arg package_fingerprint "$fingerprint" \
    --arg source_commit "$source_commit" \
    --arg upstream_version "$upstream_version" \
    --arg upstream_tag "$upstream_tag" \
    --arg upstream_tag_object "$upstream_tag_object" \
    --arg upstream_commit "$upstream_commit" \
    --arg upstream_package_hash "$package_hash" \
    --arg header_sha256 "$header_sha" \
    --arg sync_header_sha256 "$sync_header_sha" \
    --arg kind "$kind" \
    --arg target "$target" \
    --arg linkage "$linkage" \
    --argjson sync_enabled "$sync" \
    --arg native_name "$native_name" \
    --argjson abi_symbol_count "$abi_symbol_count" \
    --arg features "$features" \
    --arg optimize "$optimize" \
    --arg zig_version "$zig_version" \
    --arg rust_version "$rust_version" \
    --arg cargo_version "$cargo_version" \
    --arg ci_run_url "$ci_run_url" \
    --arg cpu_baseline "$cpu_baseline" \
    --arg minimum_platform "$minimum_platform" \
    --arg source_date_epoch "$source_epoch" \
    --arg wrapper_license_sha256 "$wrapper_license_sha" \
    --arg wrapper_notice_sha256 "$wrapper_notice_sha" \
    --arg upstream_license_sha256 "$upstream_license_sha" \
    --arg upstream_notice_sha256 "$upstream_notice_sha" \
    --arg native_path "$native_path" \
    --arg native_sha256 "$native_sha" \
    --argjson native_size "$native_size" \
    --arg native_identity "$native_identity_text" \
    --arg dependency_evidence_path "$(if [[ "$kind" == native ]]; then printf '%s' evidence/native-dependencies.txt; fi)" \
    --arg dependency_evidence_sha256 "$native_deps_sha" \
    --arg import_path "$import_path" \
    --arg import_sha256 "$import_sha" \
    '{
        schema_version: 1,
        package: {
            name: "turso.zig",
            version: $package_version,
            fingerprint: $package_fingerprint,
            source_commit: $source_commit
        },
        upstream: {
            version: $upstream_version,
            tag: $upstream_tag,
            tag_object: $upstream_tag_object,
            commit: $upstream_commit,
            zig_package_hash: $upstream_package_hash,
            header_sha256: $header_sha256,
            sync_header_sha256: (if $sync_header_sha256 == "" then null else $sync_header_sha256 end)
        },
        build: {
            kind: $kind,
            target: $target,
            linkage: $linkage,
            sync_enabled: $sync_enabled,
            features: ($features | split(",")),
            optimize: $optimize,
            cpu_baseline: (if $cpu_baseline == "" then null else $cpu_baseline end),
            minimum_platform: (if $minimum_platform == "" then null else $minimum_platform end),
            ci_run_url: $ci_run_url
        },
        abi: {
            variant: (if $sync_enabled then "sync" else "base" end),
            headers: (if $sync_enabled then ["include/turso.h", "include/turso_sync.h"] else ["include/turso.h"] end),
            symbol_manifests: (if $sync_enabled then ["tests/expected-base-symbols.txt", "tests/expected-sync-symbols.txt"] else ["tests/expected-base-symbols.txt"] end),
            symbol_count: $abi_symbol_count
        },
        tools: {
            zig: $zig_version,
            rustc: $rust_version,
            cargo: $cargo_version
        },
        licenses: {
            wrapper: {
                license_path: "LICENSE",
                license_sha256: $wrapper_license_sha256,
                notice_path: "NOTICE",
                notice_sha256: $wrapper_notice_sha256
            },
            upstream: {
                license_path: "licenses/turso/LICENSE.md",
                license_sha256: $upstream_license_sha256,
                notice_path: "licenses/turso/NOTICE.md",
                notice_sha256: $upstream_notice_sha256
            }
        },
        reproducibility: {
            source_date_epoch: ($source_date_epoch | tonumber),
            archive_format: "tar.gz",
            normalized_owner: 0,
            normalized_group: 0
        },
        native: (if $kind == "native" then {
            library_name: $native_name,
            path: $native_path,
            sha256: $native_sha256,
            size_bytes: $native_size,
            identity: $native_identity,
            abi_symbol_count: $abi_symbol_count,
            dependency_evidence: {
                path: $dependency_evidence_path,
                sha256: $dependency_evidence_sha256
            },
            import_library: (if $import_path == "" then null else {
                path: $import_path,
                sha256: $import_sha256
            } end)
        } else null end)
    }' >"$package_root/manifest.json"

reject_path_leaks "$package_root/manifest.json" "release manifest"

find "$package_root" -type d -exec chmod 0755 {} +
find "$package_root" -type f -exec chmod 0644 {} +
find "$package_root" -type f -name '*.sh' -exec chmod 0755 {} +

checksum_tmp=$(mktemp "${TMPDIR:-/tmp}/turso-checksums.XXXXXX")
(
    cd "$package_root"
    find . -type f ! -name SHA256SUMS -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum |
        sed 's#  \./#  #' >"$checksum_tmp"
    mv "$checksum_tmp" SHA256SUMS
    chmod 0644 SHA256SUMS
)

rm -f -- "$archive" "$sidecar"
(
    cd "$stage_root"
    tar --sort=name \
        --mtime="@$source_epoch" \
        --owner=0 --group=0 --numeric-owner \
        --format=posix \
        --pax-option=delete=atime,delete=ctime \
        -cf - "$package_name" |
        gzip -n -9 >"$archive"
)
archive_sha=$(sha256_file "$archive")
printf '%s  %s\n' "$archive_sha" "$(basename "$archive")" >"$sidecar"

echo "$archive"
echo "$sidecar"
