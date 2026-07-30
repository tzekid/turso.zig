#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 7 ]] || {
    echo "usage: run-cargo-build.sh SOURCE_ROOT TARGET_DIR CARGO_HOME|- windows|unix RUST_TARGET MUSL_DYNAMIC CARGO_ARGS..." >&2
    exit 64
}

source_root=$1
target_dir=$2
cargo_home=$3
platform=$4
rust_target=$5
musl_dynamic=$6
shift 6

[[ -d $source_root ]]
mkdir -p "$target_dir"
source_root=$(cd "$source_root" && pwd -P)
target_dir=$(cd "$target_dir" && pwd -P)

encoded_separator=$'\x1f'
binding_rust_flags="--remap-path-prefix=$source_root=/turso-src${encoded_separator}--remap-path-prefix=$target_dir=/turso-target"
if [[ $cargo_home != - ]]; then
    binding_rust_flags+="${encoded_separator}--remap-path-prefix=$cargo_home=/cargo-home"
fi
if [[ $musl_dynamic == true ]]; then
    binding_rust_flags+="${encoded_separator}-C${encoded_separator}target-feature=-crt-static"
fi

if [[ -n ${CARGO_ENCODED_RUSTFLAGS:-} ]]; then
    export CARGO_ENCODED_RUSTFLAGS+="${encoded_separator}${binding_rust_flags}"
elif [[ -n ${RUSTFLAGS:-} ]]; then
    inherited=${RUSTFLAGS//$'\t'/$encoded_separator}
    inherited=${inherited//$'\n'/$encoded_separator}
    inherited=${inherited// /$encoded_separator}
    export CARGO_ENCODED_RUSTFLAGS="${inherited}${encoded_separator}${binding_rust_flags}"
else
    export CARGO_ENCODED_RUSTFLAGS=$binding_rust_flags
fi

if [[ $platform == windows ]]; then
    option_prefix=/pathmap:
else
    option_prefix=-ffile-prefix-map=
fi

shell_quote() {
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

source_flag=$(shell_quote "${option_prefix}${source_root}=/turso-src")
target_flag=$(shell_quote "${option_prefix}${target_dir}=/turso-target")
native_remap_flags="$source_flag $target_flag"
if [[ $cargo_home != - ]]; then
    native_remap_flags+=" $(shell_quote "${option_prefix}${cargo_home}=/cargo-home")"
fi

export CC_SHELL_ESCAPED_FLAGS=1
normalized_target=${rust_target//-/_}
for prefix in CFLAGS CXXFLAGS; do
    key="${prefix}_${normalized_target}"
    inherited=${!key:-}
    if [[ -n $inherited ]]; then
        export "$key=$inherited $native_remap_flags"
    else
        export "$key=$native_remap_flags"
    fi
done

cd "$source_root"
exec cargo "$@" --target-dir "$target_dir"
