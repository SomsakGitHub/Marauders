#!/bin/sh
#
# Tests for Scripts/check-release-config.sh.
#
# Every case writes a fixture Info.plist, a fixture environments table and a fake app bundle with a fixture
# executable into a temporary folder, runs the guard on them and looks at what it printed. Run it from anywhere:
#
#     sh Marauders-ios/Scripts/tests/check-release-config-tests.sh
#
# It prints every failed expectation with the guard's output and exits 1 when anything failed.

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../check-release-config.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-release-config-tests.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

PRODUCTION_URL="https://marauders-api.js6ctz7gtj.workers.dev"
STAGING_URL="https://marauders-api-staging.js6ctz7gtj.workers.dev"

cases=0
failures=0
CURRENT=""

# write_table: the environments table, with the two URLs this file expects.
write_table() {
    cat >"$ENVIRONMENTS" <<EOF
{
  "staging": { "worker": "marauders-api-staging", "url": "$STAGING_URL" },
  "production": { "worker": "marauders-api", "url": "$PRODUCTION_URL" }
}
EOF
}

# write_plist <value>: a built Info.plist whose MARAUDERS_API_BASE_URL is <value>, written as it is (no expansion).
write_plist() {
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '%s\n' '<key>CFBundleIdentifier</key><string>com.somsak.Marauders</string>'
        printf '<key>MARAUDERS_API_BASE_URL</key><string>%s</string>\n' "$1"
        printf '%s\n' '</dict></plist>'
    } >"$INFO_PLIST"
}

# begin <name>: a fresh case with production's URL in the plist, the table in place and an app bundle whose executable
# holds the neighbours of the Debug-only type names (so a guard that matches too loosely fails the passing cases) but
# not the names themselves, with binary bytes around them.
begin() {
    CURRENT="$1"
    cases=$((cases + 1))
    CASE_DIR=$(mktemp -d "$WORK/case.XXXXXX")
    INFO_PLIST="$CASE_DIR/Info.plist"
    ENVIRONMENTS="$CASE_DIR/environments.json"
    BUNDLE="$CASE_DIR/Marauders.app"
    EXECUTABLE="$BUNDLE/Marauders"
    mkdir -p "$BUNDLE"
    printf '\000\001some bytes AppLogStore CopyableStatusBanner DebugLog LogView\377\000\n' >"$EXECUTABLE"
    write_table
    write_plist "$PRODUCTION_URL"
}

# run: OUT holds everything the guard printed, STATUS its exit status.
run() {
    OUT=$(sh "$GUARD" --info-plist "$INFO_PLIST" --environments "$ENVIRONMENTS" --bundle "$BUNDLE" --executable "$EXECUTABLE" 2>&1)
    STATUS=$?
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL  %s: %s\n' "$CURRENT" "$1"
    printf '%s\n' "$OUT" | sed 's/^/        | /'
}

# expect_status <n>: the guard exited with n.
expect_status() {
    [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS"
}

# expect_text <text>: the output holds it.
expect_text() {
    case "$OUT" in
    *"$1"*) ;;
    *) fail "expected the output to contain: $1" ;;
    esac
}

# expect_errors_only: the guard printed something and every line starts with "error: ".
expect_errors_only() {
    [ -n "$OUT" ] || fail "expected error lines, got no output"
    printf '%s\n' "$OUT" | while IFS= read -r line; do
        case "$line" in
        "error: "*) ;;
        *) echo "not an error line: $line" ;;
        esac
    done | grep -q . && fail "every line of a failure must start with \"error: \""
}

# expect_failure <text>: exit 1, only "error: " lines, and one of them says <text>.
expect_failure() {
    expect_status 1
    expect_errors_only
    expect_text "$1"
}

begin "passes with production's URL and no stray plist"
run
expect_status 0
expect_text "release config ok: $PRODUCTION_URL"

begin "fails when the URL is staging's"
write_plist "$STAGING_URL"
run
expect_failure "error: "
expect_text "$STAGING_URL"
expect_text "$PRODUCTION_URL"

begin "fails when the key is missing"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.somsak.Marauders</string></dict></plist>' >"$INFO_PLIST"
run
expect_failure "MARAUDERS_API_BASE_URL"

begin 'fails when the key is the literal $(MARAUDERS_API_BASE_URL)'
write_plist '$(MARAUDERS_API_BASE_URL)'
run
expect_failure 'MARAUDERS_API_BASE_URL'
expect_text "$PRODUCTION_URL"

begin "fails when APIConfiguration.plist is in the bundle"
: >"$BUNDLE/APIConfiguration.plist"
run
expect_failure "APIConfiguration.plist"

begin "fails when APIConfiguration.plist is in a folder of the bundle"
mkdir -p "$BUNDLE/Frameworks/Inner.framework"
: >"$BUNDLE/Frameworks/Inner.framework/APIConfiguration.plist"
run
expect_failure "APIConfiguration.plist"

begin "reports every problem, not only the first"
write_plist "$STAGING_URL"
: >"$BUNDLE/APIConfiguration.plist"
run
expect_status 1
expect_errors_only
expect_text "$STAGING_URL"
expect_text "APIConfiguration.plist"
errors=$(printf '%s\n' "$OUT" | grep -c '^error: ')
[ "$errors" -ge 2 ] || fail "expected at least two error lines, got $errors"

begin "fails when the table cannot be read"
rm "$ENVIRONMENTS"
run
expect_failure "environments"

begin "fails when the table has no production url"
printf '%s\n' '{ "staging": { "url": "https://s.example" } }' >"$ENVIRONMENTS"
run
expect_failure "production"

begin "fails when the table is not JSON"
printf '%s\n' 'not json at all' >"$ENVIRONMENTS"
run
expect_failure "environments"

begin "fails when the Info.plist cannot be read"
rm "$INFO_PLIST"
run
expect_failure "Info.plist"

begin "fails when the Info.plist is not a plist"
printf '%s\n' 'this is not a property list' >"$INFO_PLIST"
run
expect_failure "Info.plist"

begin "fails when the bundle does not exist"
rm -rf "$BUNDLE"
run
expect_failure "bundle"

begin "fails when an argument is missing"
OUT=$(sh "$GUARD" --info-plist "$INFO_PLIST" --environments "$ENVIRONMENTS" 2>&1)
STATUS=$?
expect_failure "--bundle"

begin "fails on an argument it does not know"
OUT=$(sh "$GUARD" --info-plist "$INFO_PLIST" --environments "$ENVIRONMENTS" --bundle "$BUNDLE" --lenient 2>&1)
STATUS=$?
expect_failure "--lenient"

begin 'every failure starts with "error: " and exits 1'
# Five different ways to fail; each must exit 1 and print nothing but error lines.
write_plist "$STAGING_URL"
run
expect_status 1
expect_errors_only
write_plist "$PRODUCTION_URL"
rm "$ENVIRONMENTS"
run
expect_status 1
expect_errors_only
write_table
rm "$INFO_PLIST"
run
expect_status 1
expect_errors_only
write_plist "$PRODUCTION_URL"
: >"$BUNDLE/APIConfiguration.plist"
run
expect_status 1
expect_errors_only
rm "$BUNDLE/APIConfiguration.plist"
run
expect_status 0

begin "fails when the executable holds the in-app log"
printf 'x DebugLogView y' >>"$EXECUTABLE"
run
expect_failure "DebugLogView"

begin "fails when the executable holds the dev login"
printf 'x DevAuthAPIClient y' >>"$EXECUTABLE"
run
expect_failure "DevAuthAPIClient"

begin "names every Debug-only type it finds"
printf 'DebugLogView DevAuthAPIClient' >>"$EXECUTABLE"
run
expect_failure "DebugLogView"
expect_text "DevAuthAPIClient"
errors=$(printf '%s\n' "$OUT" | grep -c '^error: ')
[ "$errors" -ge 2 ] || fail "expected one error line for each type, got $errors"

begin "finds a type name in the middle of binary noise"
printf '\000\377\376DebugLogView\000\001\002' >>"$EXECUTABLE"
run
expect_failure "DebugLogView"

begin "passes with the neighbours of the names but not the names"
run
expect_status 0

begin "fails when the executable does not exist"
rm "$EXECUTABLE"
run
expect_failure "executable"

begin "fails when --executable is missing"
OUT=$(sh "$GUARD" --info-plist "$INFO_PLIST" --environments "$ENVIRONMENTS" --bundle "$BUNDLE" 2>&1)
STATUS=$?
expect_failure "--executable"

# A grep that exits 2 (it could not read the file, say) has not found "the name is not there": the guard must fail on
# it. A fake grep sits first in PATH for this one run, so the case does not depend on who runs the tests (a file with
# no read permission would still be readable by root).
begin "fails when grep cannot search the executable"
mkdir -p "$CASE_DIR/bin"
printf '#!/bin/sh\nexit 2\n' >"$CASE_DIR/bin/grep"
chmod +x "$CASE_DIR/bin/grep"
OUT=$(PATH="$CASE_DIR/bin:$PATH" sh "$GUARD" --info-plist "$INFO_PLIST" --environments "$ENVIRONMENTS" --bundle "$BUNDLE" --executable "$EXECUTABLE" 2>&1)
STATUS=$?
expect_failure "could not be searched"
expect_text "DebugLogView"
expect_text "DevAuthAPIClient"

# With a debug dylib in the bundle the app's code lives there and the executable is a small stub, so a guard that reads
# only the executable would pass whatever the code holds.
begin "fails when the bundle holds a debug dylib"
: >"$BUNDLE/Marauders.debug.dylib"
run
expect_failure "Marauders.debug.dylib"

begin "fails when a folder of the bundle holds a debug dylib"
mkdir -p "$BUNDLE/Frameworks/Inner.framework"
: >"$BUNDLE/Frameworks/Inner.framework/Inner.debug.dylib"
run
expect_failure "Inner.debug.dylib"

begin "passes with other dylibs in the bundle"
mkdir -p "$BUNDLE/Frameworks"
: >"$BUNDLE/Frameworks/Library.dylib"
run
expect_status 0

if [ "$failures" -gt 0 ]; then
    printf 'check-release-config: %s of %s expectation checks failed\n' "$failures" "$cases"
    exit 1
fi
printf 'check-release-config: all %s cases passed\n' "$cases"
