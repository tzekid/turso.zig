#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
header="$repo_root/include/turso.h"
expected="$repo_root/tests/expected-base-symbols.txt"
sync_header="$repo_root/include/turso_sync.h"
sync_expected="$repo_root/tests/expected-sync-symbols.txt"
header_only=false
sync=false
libraries=()

usage() {
    cat <<'EOF'
usage: tools/check-abi-symbols.sh [options] [LIBRARY ...]

Compare the pinned base SDK Kit function manifest with include/turso.h and each
native library. With --sync, also compare the sync header/manifest and require
the selected library to export exactly the union of base and sync symbols.
Static archives, ELF/Mach-O shared libraries, Windows DLLs, and MSVC import
libraries are supported when a suitable symbol tool is available.

options:
  --header PATH       C header to inspect (default: include/turso.h)
  --expected PATH     sorted expected manifest
  --sync              also require the pinned sync ABI
  --sync-header PATH  sync C header (default: include/turso_sync.h)
  --sync-expected PATH
                      sorted sync manifest
  --header-only       compare the header and manifest without a library
  -h, --help          show this help

Exit 2 means the platform has no supported symbol inspection tool.
EOF
}

while (($#)); do
    case "$1" in
        --header)
            (($# >= 2)) || { echo "--header requires a path" >&2; exit 64; }
            header=$2
            shift 2
            ;;
        --expected)
            (($# >= 2)) || { echo "--expected requires a path" >&2; exit 64; }
            expected=$2
            shift 2
            ;;
        --sync)
            sync=true
            shift
            ;;
        --sync-header)
            (($# >= 2)) || { echo "--sync-header requires a path" >&2; exit 64; }
            sync_header=$2
            shift 2
            ;;
        --sync-expected)
            (($# >= 2)) || { echo "--sync-expected requires a path" >&2; exit 64; }
            sync_expected=$2
            shift 2
            ;;
        --header-only)
            header_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            libraries+=("$@")
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            libraries+=("$1")
            shift
            ;;
    esac
done

[[ -f "$header" ]] || { echo "header not found: $header" >&2; exit 66; }
[[ -f "$expected" ]] || { echo "expected manifest not found: $expected" >&2; exit 66; }
if $sync; then
    [[ -f "$sync_header" ]] || { echo "sync header not found: $sync_header" >&2; exit 66; }
    [[ -f "$sync_expected" ]] || { echo "sync manifest not found: $sync_expected" >&2; exit 66; }
fi
if ! $header_only && ((${#libraries[@]} == 0)); then
    echo "at least one library is required (or pass --header-only)" >&2
    usage >&2
    exit 64
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/turso-abi.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

normalize_expected() {
    sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" |
        LC_ALL=C sort -u
}

extract_header_symbols() {
    awk '
        BEGIN { RS = ";" }
        {
            record = $0
            gsub(/\n/, " ", record)
            if (record ~ /typedef/) next
            while (match(record, /turso_[[:alnum:]_]+[[:space:]]*\(/)) {
                name = substr(record, RSTART, RLENGTH)
                sub(/[[:space:]]*\($/, "", name)
                print name
                record = substr(record, RSTART + RLENGTH)
            }
        }
    ' "$1" | LC_ALL=C sort -u
}

normalize_library_symbols() {
    tr '[:space:]' '\n' <"$1" |
        sed -n -E 's/^(__imp_)?_?(turso_[A-Za-z0-9_]+)(@[0-9]+)?$/\2/p' |
        LC_ALL=C sort -u
}

try_symbol_command() {
    local output=$1
    shift
    : >"$tmp_dir/raw-symbols"
    # Archive inspectors can return non-zero after emitting valid symbols when
    # a Rust archive also contains metadata members they do not understand.
    # The exact expected-symbol comparison below remains the authority.
    "$@" >"$tmp_dir/raw-symbols" 2>/dev/null || true
    normalize_library_symbols "$tmp_dir/raw-symbols" >"$output"
    [[ -s "$output" ]]
}

extract_library_symbols() {
    local library=$1
    local output=$2
    local tool

    if command -v xcrun >/dev/null 2>&1; then
        tool=$(xcrun --find llvm-nm 2>/dev/null || true)
        if [[ -n "$tool" && -x "$tool" ]]; then
            case "$library" in
                *.so|*.so.*)
                    if try_symbol_command "$output" "$tool" --dynamic --defined-only --extern-only "$library"; then return 0; fi
                    if try_symbol_command "$output" "$tool" --defined-only --extern-only "$library"; then return 0; fi
                    ;;
                *)
                    if try_symbol_command "$output" "$tool" --defined-only --extern-only "$library"; then return 0; fi
                    if try_symbol_command "$output" "$tool" --dynamic --defined-only --extern-only "$library"; then return 0; fi
                    ;;
            esac
        fi
    fi

    case "$library" in
        *.dll|*.exe)
            for tool in llvm-readobj llvm-readobj.exe "/c/Program Files/LLVM/bin/llvm-readobj.exe"; do
                if [[ "$tool" == */* ]]; then
                    [[ -x "$tool" ]] || continue
                else
                    command -v "$tool" >/dev/null 2>&1 || continue
                fi
                if try_symbol_command "$output" "$tool" --coff-exports "$library"; then return 0; fi
            done
            ;;
    esac

    for tool in llvm-nm llvm-nm.exe "/c/Program Files/LLVM/bin/llvm-nm.exe"; do
        if [[ "$tool" == */* ]]; then
            [[ -x "$tool" ]] || continue
        else
            command -v "$tool" >/dev/null 2>&1 || continue
        fi
        case "$library" in
            *.so|*.so.*)
                if try_symbol_command "$output" "$tool" --dynamic --defined-only --extern-only "$library"; then return 0; fi
                if try_symbol_command "$output" "$tool" --defined-only --extern-only "$library"; then return 0; fi
                ;;
            *)
                if try_symbol_command "$output" "$tool" --defined-only --extern-only "$library"; then return 0; fi
                if try_symbol_command "$output" "$tool" --dynamic --defined-only --extern-only "$library"; then return 0; fi
                ;;
        esac
    done

    if command -v nm >/dev/null 2>&1; then
        case "$(uname -s 2>/dev/null || true):$library" in
            Darwin:*)
                if try_symbol_command "$output" nm -gU "$library"; then return 0; fi
                ;;
            *:*.so|*:*.so.*)
                if try_symbol_command "$output" nm -D -g --defined-only "$library"; then return 0; fi
                ;;
            *)
                if try_symbol_command "$output" nm -g --defined-only "$library"; then return 0; fi
                ;;
        esac
    fi

    for tool in dumpbin dumpbin.exe; do
        command -v "$tool" >/dev/null 2>&1 || continue
        if try_symbol_command "$output" "$tool" /nologo /exports "$library"; then
            return 0
        fi
    done

    echo "unsupported: cannot inspect symbols in $library" >&2
    echo "install llvm-readobj, llvm-nm, GNU/BSD nm, or dumpbin and retry" >&2
    return 2
}

normalize_expected "$expected" >"$tmp_dir/expected"
extract_header_symbols "$header" >"$tmp_dir/header"

if ! diff -u "$tmp_dir/expected" "$tmp_dir/header"; then
    echo "ABI manifest differs from declarations in $header" >&2
    exit 1
fi

if $sync; then
    normalize_expected "$sync_expected" >"$tmp_dir/sync-expected"
    extract_header_symbols "$sync_header" >"$tmp_dir/sync-header"
    if ! diff -u "$tmp_dir/sync-expected" "$tmp_dir/sync-header"; then
        echo "sync ABI manifest differs from declarations in $sync_header" >&2
        exit 1
    fi
    LC_ALL=C sort -u "$tmp_dir/expected" "$tmp_dir/sync-expected" >"$tmp_dir/library-expected"
else
    cp "$tmp_dir/expected" "$tmp_dir/library-expected"
fi

for library in "${libraries[@]}"; do
    [[ -f "$library" ]] || { echo "library not found: $library" >&2; exit 66; }
    if extract_library_symbols "$library" "$tmp_dir/library"; then
        :
    else
        status=$?
        exit "$status"
    fi
    if ! diff -u "$tmp_dir/library-expected" "$tmp_dir/library"; then
        echo "ABI manifest differs from exported symbols in $library" >&2
        exit 1
    fi
    count=$(wc -l <"$tmp_dir/library" | tr -d '[:space:]')
    echo "ABI symbols OK ($count): $library"
done

if $header_only; then
    count=$(wc -l <"$tmp_dir/library-expected" | tr -d '[:space:]')
    if $sync; then
        echo "ABI header manifests OK ($count total): $header + $sync_header"
    else
        echo "ABI header manifest OK ($count): $header"
    fi
fi
