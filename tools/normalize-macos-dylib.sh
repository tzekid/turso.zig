#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
    echo "usage: normalize-macos-dylib INPUT OUTPUT INSTALL_NAME" >&2
    exit 64
fi

input=$1
output=$2
install_name=$3

case "$install_name" in
    @rpath/*.dylib) ;;
    *)
        echo "normalize-macos-dylib: install name must be an @rpath dylib" >&2
        exit 64
        ;;
esac

command -v install_name_tool >/dev/null 2>&1 ||
    { echo "normalize-macos-dylib: install_name_tool is required" >&2; exit 69; }
command -v otool >/dev/null 2>&1 ||
    { echo "normalize-macos-dylib: otool is required" >&2; exit 69; }
command -v codesign >/dev/null 2>&1 ||
    { echo "normalize-macos-dylib: codesign is required" >&2; exit 69; }

cp "$input" "$output"
install_name_tool -id "$install_name" "$output"
codesign --force --sign - "$output"
codesign --verify --strict "$output"

actual=$(otool -D "$output" | tail -n 1)
[[ "$actual" == "$install_name" ]] || {
    echo "normalize-macos-dylib: expected $install_name, found $actual" >&2
    exit 1
}
