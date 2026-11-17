#!/bin/sh
#
# Checks the layer rules of ARCHITECTURE.md ("Dependency rules") on the Swift sources under Marauders/, and on the
# source folders of local packages that belong to a layer.
#
#   check-layers.sh [--strict] [--root DIR] [--exceptions FILE] [--modules FILE]
#
#   --root DIR          folder holding App/, Composition/, Domain/, Data/, Presentation/ and Shared/
#                       (default: ../Marauders next to this script)
#   --exceptions FILE   accepted exceptions, one "<path>: <type or import Module>  # reason" per line; <path> is
#                       under root, or, for a file of a module folder, under the folder that holds root
#                       (default: layer-exceptions.txt next to this script)
#   --modules FILE      folders outside root that belong to a layer, one "<Layer>: <folder>  # what it holds" per
#                       line; <folder> is relative to the folder that holds root, and its last component is the
#                       module's name. A file that does not exist means there are none.
#                       (default: layer-modules.txt next to this script)
#   --strict            exit 1 when anything is reported (default: report and exit 0, so a build phase only warns)
#
# What it checks, by the folder a file sits in (a type belongs to the folder that declares it at the top level):
#
#   Domain        imports Foundation and Domain modules only; names no Data, Presentation or Shared type
#   Data          does not import SwiftUI; names no Presentation type
#   Presentation  names no Data type; a *View.swift file also names no Domain use case or repository
#   Shared        imports no UI framework; names no type of another layer
#   Composition and App may name anything.
#
# A file under a module folder is a file of that folder's layer: the rules above apply to it, and the types it declares
# belong to that layer. An import of a module folder's module is judged like naming a type of its layer: it is allowed
# where such a type may be named, and reported where it may not.
#
# Every finding is printed as "<path>:<line>: warning: [layer] ...", the format Xcode turns into an issue. A finding
# listed in the exceptions file is not printed, and an exception that no longer matches anything is printed instead,
# so the list only ever shrinks. Text in comments and string literals is ignored, and so is everything inside a
# #Preview block (a preview may wire any layer together).
#
# Tests: sh Scripts/tests/check-layers-tests.sh

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../Marauders"
EXCEPTIONS="$HERE/layer-exceptions.txt"
MODULES="$HERE/layer-modules.txt"
STRICT=0

while [ $# -gt 0 ]; do
    case "$1" in
    --strict) STRICT=1 ;;
    --root | --exceptions | --modules)
        if [ $# -lt 2 ]; then
            echo "error: $1 needs a value" >&2
            exit 2
        fi
        case "$1" in
        --root) ROOT="$2" ;;
        --exceptions) EXCEPTIONS="$2" ;;
        --modules) MODULES="$2" ;;
        esac
        shift
        ;;
    *)
        echo "error: unknown option: $1" >&2
        exit 2
        ;;
    esac
    shift
done

if [ ! -d "$ROOT" ]; then
    echo "error: source folder not found: $ROOT" >&2
    exit 2
fi
ROOT=$(cd "$ROOT" && pwd)
BASE=$(cd "$ROOT/.." && pwd)
[ -r "$EXCEPTIONS" ] || EXCEPTIONS=/dev/null

AWK=/usr/bin/awk
[ -x "$AWK" ] || AWK=awk

LIST=$(mktemp "${TMPDIR:-/tmp}/check-layers.XXXXXX") || exit 2
FOLDERS=$(mktemp "${TMPDIR:-/tmp}/check-layers.XXXXXX") || exit 2
trap 'rm -f "$LIST" "$FOLDERS"' EXIT
find "$ROOT" -type f -name '*.swift' | sort >"$LIST"

# The module folders: checked here, then handed to awk as "<Layer><tab><absolute folder>" lines.
if [ -r "$MODULES" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        text=$(printf '%s\n' "$line" | sed -e 's/[[:space:]]\{1,\}#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$text" in
        "" | "#"*) continue ;;
        *": "*) ;;
        *)
            echo "error: malformed line in $MODULES: $line" >&2
            exit 2
            ;;
        esac
        layer=${text%%: *}
        folder=$(printf '%s\n' "${text#*: }" | sed -e 's/^[[:space:]]*//')
        case "$layer" in
        App | Composition | Presentation | Data | Domain | Shared) ;;
        *)
            echo "error: unknown layer in $MODULES: $layer" >&2
            exit 2
            ;;
        esac
        dir="$BASE/$folder"
        if [ ! -d "$dir" ]; then
            echo "error: module folder not found: $folder" >&2
            exit 2
        fi
        dir=$(cd "$dir" && pwd)
        printf '%s\t%s\n' "$layer" "$dir" >>"$FOLDERS"
        find "$dir" -type f -name '*.swift' | sort >>"$LIST"
    done <"$MODULES"
fi

"$AWK" -v root="$ROOT" -v base="$BASE" -v list="$LIST" -v folders="$FOLDERS" -v exceptions="$EXCEPTIONS" \
    -v strict="$STRICT" -f "$HERE/check-layers.awk"
