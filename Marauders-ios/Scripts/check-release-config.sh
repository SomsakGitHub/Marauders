#!/bin/sh
#
# The Production guard (its Run Script phase is still called "release config check"): a Production build
# (configuration Release-Production) must talk to the production Worker, it must not carry a second copy of the URL,
# and it must not carry a Debug-only type. It is the last step of a Production build (a Run Script phase of the app
# target, see project.pbxproj) and runs on the built app, so it checks what would ship, not what the project says.
#
#     sh Scripts/check-release-config.sh --info-plist <built Info.plist> --environments <environments.json> \
#         --bundle <Marauders.app> --executable <the app's executable>
#
# Exit 0 and "release config ok: <url>" only when
#   - MARAUDERS_API_BASE_URL in the built Info.plist equals production.url of the environments table
#     (backend/environments.json, read with plutil),
#   - no APIConfiguration.plist, the file that used to hold the URL, is anywhere inside the app bundle,
#   - no *.debug.dylib is anywhere inside the app bundle: with one, the app's code lives in it and the executable is
#     only a small stub, so the search of the executable below would find nothing whatever the code holds, and
#   - the executable holds none of the names in DEBUG_ONLY_TYPES: the in-app log and the dev login exist only in
#     Staging (DEBUG) builds.
# Every failure prints one or more lines that start with "error: " (Xcode lists such a line as a build error) and
# exits 1. The guard fails closed: a plist or a table it cannot read, a key that is missing, an executable that is
# not there and an executable that grep cannot search are failures, never a pass. It reads files and prints; it
# changes nothing.

# The types that exist only in Staging (DEBUG) builds: the in-app log screen and the dev login's API client. They must
# stay declared in the Swift sources: backend/test/scripts/iosEnvironments.test.mjs fails when one is not, so this
# list can never look for a name that no longer exists.
DEBUG_ONLY_TYPES="DebugLogView DevAuthAPIClient"

problems=0

usage_error() {
    printf 'error: %s\n' "$1"
    printf 'error: usage: check-release-config.sh --info-plist <Info.plist> --environments <environments.json> --bundle <Marauders.app> --executable <executable>\n'
    exit 1
}

problem() {
    printf 'error: %s\n' "$1"
    problems=$((problems + 1))
}

info_plist=""
environments=""
bundle=""
executable=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --info-plist | --environments | --bundle | --executable)
        [ "$#" -ge 2 ] || usage_error "$1 needs a value"
        case "$1" in
        --info-plist) info_plist=$2 ;;
        --environments) environments=$2 ;;
        --bundle) bundle=$2 ;;
        --executable) executable=$2 ;;
        esac
        shift 2
        ;;
    *) usage_error "unknown argument: $1" ;;
    esac
done
[ -n "$info_plist" ] || usage_error "--info-plist is required"
[ -n "$environments" ] || usage_error "--environments is required"
[ -n "$bundle" ] || usage_error "--bundle is required"
[ -n "$executable" ] || usage_error "--executable is required"

# extract <key path> <file>: the value, or nothing when the file or the key cannot be read.
extract() {
    plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

expected=$(extract production.url "$environments")
if [ -z "$expected" ]; then
    problem "the environments table $environments has no readable production.url"
fi

actual=$(extract MARAUDERS_API_BASE_URL "$info_plist")
if [ -z "$actual" ]; then
    problem "the built Info.plist $info_plist has no readable MARAUDERS_API_BASE_URL"
fi

if [ -n "$expected" ] && [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
    problem "a Production build must be built for production: MARAUDERS_API_BASE_URL in the built Info.plist is $actual, but production.url in the environments table is $expected"
fi

if [ ! -d "$bundle" ]; then
    problem "the app bundle $bundle does not exist"
else
    stray=$(find "$bundle" -name APIConfiguration.plist 2>/dev/null)
    if [ -n "$stray" ]; then
        problems=$((problems + 1))
        printf '%s\n' "$stray" | while IFS= read -r path; do
            printf 'error: APIConfiguration.plist is inside the app bundle (%s): the URL comes from the MARAUDERS_API_BASE_URL build setting only\n' "$path"
        done
    fi
    debug_dylibs=$(find "$bundle" -name '*.debug.dylib' 2>/dev/null)
    if [ -n "$debug_dylibs" ]; then
        problems=$((problems + 1))
        printf '%s\n' "$debug_dylibs" | while IFS= read -r path; do
            printf 'error: %s is inside the app bundle: a Production build must not carry a debug dylib, because the app code would live there and the guard reads only the executable (see ENABLE_DEBUG_DYLIB)\n' "$path"
        done
    fi
fi

if [ ! -f "$executable" ]; then
    problem "the executable $executable does not exist"
else
    for debug_type in $DEBUG_ONLY_TYPES; do
        # grep exits 0 when it finds the name, 1 when it does not and 2 or more when it could not search at all:
        # only 1 is a pass.
        LC_ALL=C grep -aq -- "$debug_type" "$executable"
        status=$?
        if [ "$status" -eq 0 ]; then
            problem "the executable $executable contains $debug_type, a Debug-only type: a Production build must carry neither the in-app log nor the dev login"
        elif [ "$status" -ne 1 ]; then
            problem "the executable $executable could not be searched for $debug_type (grep exited with status $status): the guard cannot tell whether it holds a Debug-only type"
        fi
    done
fi

if [ "$problems" -gt 0 ]; then
    exit 1
fi
printf 'release config ok: %s\n' "$actual"
