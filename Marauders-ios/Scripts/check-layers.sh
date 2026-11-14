#!/bin/sh
#
# Checks the layer rules of ARCHITECTURE.md ("Dependency rules") on the Swift sources under Marauders/.
#
#   check-layers.sh [--strict] [--root DIR] [--exceptions FILE]
#
#   --root DIR          folder holding App/, Composition/, Domain/, Data/, Presentation/ and Shared/
#                       (default: ../Marauders next to this script)
#   --exceptions FILE   accepted exceptions, one "<path under root>: <type or import Module>  # reason" per line
#                       (default: layer-exceptions.txt next to this script)
#   --strict            exit 1 when anything is reported (default: report and exit 0, so a build phase only warns)
#
# What it checks, by the folder a file sits in (a type belongs to the folder that declares it at the top level):
#
#   Domain        imports Foundation only; names no Data, Presentation or Shared type
#   Data          does not import SwiftUI; names no Presentation type
#   Presentation  names no Data type; a *View.swift file also names no Domain use case or repository
#   Shared        imports no UI framework; names no type of another layer
#   Composition and App may name anything.
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
STRICT=0

while [ $# -gt 0 ]; do
    case "$1" in
    --strict) STRICT=1 ;;
    --root | --exceptions)
        if [ $# -lt 2 ]; then
            echo "error: $1 needs a value" >&2
            exit 2
        fi
        if [ "$1" = "--root" ]; then ROOT="$2"; else EXCEPTIONS="$2"; fi
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
[ -r "$EXCEPTIONS" ] || EXCEPTIONS=/dev/null

AWK=/usr/bin/awk
[ -x "$AWK" ] || AWK=awk

LIST=$(mktemp "${TMPDIR:-/tmp}/check-layers.XXXXXX") || exit 2
trap 'rm -f "$LIST"' EXIT
find "$ROOT" -type f -name '*.swift' | sort >"$LIST"

"$AWK" -v root="$ROOT" -v list="$LIST" -v exceptions="$EXCEPTIONS" -v strict="$STRICT" -f "$HERE/check-layers.awk"
