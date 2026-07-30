#!/usr/bin/env bash
set -euo pipefail

arch=
variant=
source_root=
work_root=
ci_run_url=

usage() {
    cat <<'USAGE'
usage: tests/release-package-musl.sh OPTIONS

Required:
  --arch x86_64|aarch64
  --variant base|sync
  --source-root DIR
  --work-root DIR
  --ci-run-url URL

Run inside the pinned Alpine release container. The script installs no system
packages; its caller must provide Bash, binutils, a native C toolchain, Git,
curl, jq, GNU tar, gzip, xz, and rustup-init.
USAGE
}

while (($#)); do
    case "$1" in
        --arch) arch=${2:?}; shift 2 ;;
        --variant) variant=${2:?}; shift 2 ;;
        --source-root) source_root=${2:?}; shift 2 ;;
        --work-root) work_root=${2:?}; shift 2 ;;
        --ci-run-url) ci_run_url=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

for value in "$arch" "$variant" "$source_root" "$work_root" "$ci_run_url"; do
    [[ -n "$value" ]] || { usage >&2; exit 64; }
done

case "$arch" in
    x86_64)
        expected_uname=x86_64
        expected_apk_arch=x86_64
        zig_asset=x86_64-linux
        zig_target=x86_64-linux-musl
        rust_target=x86_64-unknown-linux-musl
        cpu_baseline=x86-64-v1
        musl_soname=libc.musl-x86_64.so.1
        ;;
    aarch64)
        expected_uname=aarch64
        expected_apk_arch=aarch64
        zig_asset=aarch64-linux
        zig_target=aarch64-linux-musl
        rust_target=aarch64-unknown-linux-musl
        cpu_baseline=armv8-a
        musl_soname=libc.musl-aarch64.so.1
        ;;
    *) echo "unsupported musl architecture: $arch" >&2; exit 64 ;;
esac

case "$variant" in
    base)
        sdk_name=turso_sdk_kit
        features=encryption,pure-rust-crypto
        build_sync_args=()
        package_sync_args=()
        ;;
    sync)
        sdk_name=turso_sync_sdk_kit
        features=pure-rust-crypto
        build_sync_args=(-Dsync=true)
        package_sync_args=(--sync)
        ;;
    *) echo "unsupported SDK Kit variant: $variant" >&2; exit 64 ;;
esac

[[ "$(uname -m)" == "$expected_uname" ]] ||
    { echo "container architecture does not match requested target" >&2; exit 1; }
[[ "$(apk --print-arch)" == "$expected_apk_arch" ]] ||
    { echo "Alpine package architecture does not match requested target" >&2; exit 1; }
[[ "$work_root" != / && "$work_root" != "$source_root" ]] ||
    { echo "unsafe musl work root" >&2; exit 64; }

source_root=$(realpath "$source_root")
mkdir -p "$work_root"
work_root=$(realpath "$work_root")
repo_root="$work_root/repo"
upstream_root="$work_root/upstream"
toolchain_root="$work_root/zig"
cargo_home="$work_root/cargo-home"
rustup_home="$work_root/rustup-home"

for path in "$repo_root" "$upstream_root" "$toolchain_root" "$cargo_home" "$rustup_home"; do
    [[ ! -e "$path" ]] || { echo "musl work path already exists: $path" >&2; exit 1; }
done

git config --global --add safe.directory "$source_root"
git config --global --add safe.directory "$source_root/.git"
git clone --no-hardlinks --no-checkout "$source_root" "$repo_root"
source_commit=$(git -C "$source_root" rev-parse HEAD)
git -C "$repo_root" checkout --detach "$source_commit"
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] ||
    { echo "musl release checkout is dirty" >&2; exit 1; }

zig_version=$(sed -n -E 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$repo_root/build.zig.zon" | head -1)
upstream_version=$(sed -n -E 's/^pub const upstream = "([^"]+)";/\1/p' "$repo_root/src/version.zig" | head -1)
upstream_tag=$(sed -n -E 's/^pub const upstream_tag(:[^=]+)? = "([^"]+)";/\2/p' "$repo_root/src/version.zig" | head -1)
upstream_commit=$(sed -n -E 's/^pub const upstream_commit(:[^=]+)? = "([^"]+)";/\2/p' "$repo_root/src/version.zig" | head -1)
upstream_tag_object=$(sed -n -E 's/^pub const upstream_tag_object(:[^=]+)? = "([^"]+)";/\2/p' "$repo_root/src/version.zig" | head -1)
[[ "$zig_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$upstream_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$upstream_tag" == "v$upstream_version" ]]

git clone --filter=blob:none --no-checkout https://github.com/tursodatabase/turso.git "$upstream_root"
git -C "$upstream_root" checkout --detach "$upstream_commit"
[[ "$(git -C "$upstream_root" rev-parse "$upstream_tag^{tag}")" == "$upstream_tag_object" ]]
[[ "$(git -C "$upstream_root" rev-parse "$upstream_tag^{commit}")" == "$upstream_commit" ]]

curl --fail --location --silent --show-error \
    https://ziglang.org/download/index.json -o "$work_root/zig-index.json"
zig_url=$(jq -er --arg version "$zig_version" --arg asset "$zig_asset" '.[$version][$asset].tarball' "$work_root/zig-index.json")
zig_sha256=$(jq -er --arg version "$zig_version" --arg asset "$zig_asset" '.[$version][$asset].shasum' "$work_root/zig-index.json")
zig_archive=$(basename "$zig_url")
curl --fail --location --silent --show-error \
    "$zig_url" \
    -o "$work_root/$zig_archive"
printf '%s  %s\n' "$zig_sha256" "$work_root/$zig_archive" | sha256sum --check -
mkdir -p "$toolchain_root"
tar -xJf "$work_root/$zig_archive" -C "$toolchain_root" --strip-components=1

mkdir -p "$cargo_home" "$rustup_home"
CARGO_HOME="$cargo_home" RUSTUP_HOME="$rustup_home" \
    rustup-init -y --profile minimal --default-toolchain "$(awk -F'\"' '/^channel = "/ { print $2; exit }' "$upstream_root/rust-toolchain.toml")" --no-modify-path
export PATH="$toolchain_root:$cargo_home/bin:$PATH"
export CARGO_HOME="$cargo_home"
export RUSTUP_HOME="$rustup_home"
export RUSTUP_TOOLCHAIN
RUSTUP_TOOLCHAIN=$(awk -F'"' '/^channel = "/ { print $2; exit }' "$upstream_root/rust-toolchain.toml")
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$upstream_root" show -s --format=%ct "$upstream_commit")

[[ "$(zig version)" == "$zig_version" ]]
rustc -Vv
cargo -V

artifact_root="$work_root/artifacts"
mkdir -p "$artifact_root"
(
    cd "$repo_root"
    zig build native-artifact \
        -Dtarget="$zig_target" \
        -Dnative=source \
        -Dlinkage=static \
        "${build_sync_args[@]}" \
        -Doptimize=ReleaseSafe \
        -j2
)
static_library="$artifact_root/lib$sdk_name.a"
cp "$repo_root/zig-out/lib/lib$sdk_name.a" "$static_library"

(
    cd "$repo_root"
    zig build native-artifact \
        -Dtarget="$zig_target" \
        -Dnative=source \
        -Dlinkage=dynamic \
        "${build_sync_args[@]}" \
        -Doptimize=ReleaseSafe \
        -j2
)
dynamic_library="$artifact_root/lib$sdk_name.so"
cp "$repo_root/zig-out/lib/lib$sdk_name.so" "$dynamic_library"

file "$static_library" "$dynamic_library"
readelf -h "$dynamic_library" >"$artifact_root/dynamic-file-header.txt"
grep -F 'Type:                              DYN (Shared object file)' "$artifact_root/dynamic-file-header.txt"
case "$arch" in
    x86_64) grep -F 'Machine:                           Advanced Micro Devices X86-64' "$artifact_root/dynamic-file-header.txt" ;;
    aarch64) grep -F 'Machine:                           AArch64' "$artifact_root/dynamic-file-header.txt" ;;
esac

evidence_root="$work_root/dependency-evidence"
mkdir -p "$evidence_root"
static_log="$evidence_root/native-static-libs.log"
(
    cd "$upstream_root"
    cargo rustc --locked -p "$sdk_name" --lib --profile lib-release \
        --target "$rust_target" \
        --target-dir "$work_root/cargo-evidence" \
        --no-default-features \
        --features "$features" \
        -- --print native-static-libs
) 2>&1 | tee "$static_log"
static_output=$(sed -n 's/.*native-static-libs: //p' "$static_log" | tail -1)
[[ -n "$static_output" ]] || { echo "Cargo did not report native static dependencies" >&2; exit 1; }
printf '%s\n' \
    "command=cargo rustc -p $sdk_name --lib --locked -- --print native-static-libs" \
    "target=$rust_target" \
    "output=$static_output" >"$evidence_root/native-static-libs.txt"

readelf -d "$dynamic_library" >"$evidence_root/readelf-dynamic.txt"
required=$(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' "$evidence_root/readelf-dynamic.txt" | paste -sd, -)
[[ -n "$required" ]] || { echo "musl dynamic dependency set is empty" >&2; exit 1; }
unexpected=$(
    printf '%s' "$required" |
        tr ',' '\n' |
        grep -Ev "^(libgcc_s\\.so\\.1|$musl_soname)$" || true
)
[[ -z "$unexpected" ]] || { echo "unexpected musl dynamic dependency: $unexpected" >&2; exit 1; }
printf '%s' "$required" | tr ',' '\n' | grep -Fx "$musl_soname"
if printf '%s' "$required" | grep -Fq 'libc.so.6'; then
    echo "musl dynamic library unexpectedly depends on glibc" >&2
    exit 1
fi
printf '%s\n' \
    "command=readelf -d lib$sdk_name.so" \
    "target=$rust_target" \
    "required=$required" >"$evidence_root/native-dynamic-deps.txt"

ldd --version >"$evidence_root/musl-version.txt" 2>&1 || true
grep -F 'musl libc' "$evidence_root/musl-version.txt"
grep -F 'Version 1.2.5' "$evidence_root/musl-version.txt"

release_work="$work_root/release-work"
"$repo_root/tests/release-package.sh" "${package_sync_args[@]}" --skip-source \
    --upstream-root "$upstream_root" \
    --static "$static_library" \
    --dynamic "$dynamic_library" \
    --static-deps "$evidence_root/native-static-libs.txt" \
    --dynamic-deps "$evidence_root/native-dynamic-deps.txt" \
    --target "$rust_target" \
    --cpu-baseline "$cpu_baseline" \
    --minimum-platform 'alpine-3.22 musl>=1.2.5' \
    --ci-run-url "$ci_run_url" \
    --work-root "$release_work"

upload_root="$work_root/upload"
mkdir -p "$upload_root/packages"
find "$release_work" -maxdepth 2 -type f \
    \( -name '*.tar.gz' -o -name '*.sha256' -o -name '*.json' \) \
    -exec cp {} "$upload_root/packages/" \;
[[ "$(find "$upload_root/packages" -type f -name '*.tar.gz' | wc -l)" -eq 2 ]]
cp "$evidence_root"/*.txt "$upload_root/"
cp "$artifact_root/dynamic-file-header.txt" "$upload_root/"
printf '%s\n' \
    "source_commit=$source_commit" \
    "architecture=$arch" \
    "rust_target=$rust_target" \
    "variant=$variant" \
    "zig=$(zig version)" \
    "rustc=$(rustc -V)" \
    "cargo=$(cargo -V)" \
    "alpine=$(cat /etc/alpine-release)" >"$upload_root/environment.txt"

echo "target-native musl release package integration OK: $arch $variant"
