#!/bin/sh
#
# Tests for Scripts/check-firebase-plist.sh.
#
# Every case writes a fixture GoogleService-Info.plist into a temporary folder, runs the guard on it and looks at what
# it printed. The fixtures hold only what the guard reads (GOOGLE_APP_ID, BUNDLE_ID, API_KEY, PROJECT_ID and
# GCM_SENDER_ID), with values that are markers: nothing in this file belongs to any Firebase project, and the repository
# is public. Run it from anywhere:
#
#     sh Marauders-ios/Scripts/tests/check-firebase-plist-tests.sh
#
# It prints every failed expectation with the guard's output and exits 1 when anything failed.

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../check-firebase-plist.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-firebase-plist-tests.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

APP_BUNDLE="com.somsak.Marauders"
OTHER_BUNDLE="com.example.OtherApp"
# The fixture's project number, project id and key. Nobody's, and the guard must never print any of them: the output of a
# build goes to a log that more people read than the plist. The key has the shape the SDK's Installations demands
# (39 characters, an A first, then letters, digits, - and _), spelled so that it does not look like a real key.
PROJECT_NUMBER="000000000042"
PROJECT_NAME="fixture-not-a-project"
MARKER="AFIXTURE-NOT-A-KEY$(printf '%021d' 0)"
GOOD_APP_ID="1:${PROJECT_NUMBER}:ios:0123456789abcdef"

cases=0
failures=0
CURRENT=""

# The three other keys the SDK needs, each as the XML that goes into the dict. A case overrides one (and calls
# write_plist again); an empty fragment leaves the key out.
reset_other_keys() {
    API_KEY_XML="<key>API_KEY</key><string>$MARKER</string>"
    PROJECT_ID_XML="<key>PROJECT_ID</key><string>$PROJECT_NAME</string>"
    SENDER_ID_XML="<key>GCM_SENDER_ID</key><string>$PROJECT_NUMBER</string>"
}

# write_plist <app id> <bundle id>: the fixture, with the two values written as they are (no expansion). An argument
# of "-" leaves its key out. The other three keys are what reset_other_keys or the case made them.
write_plist() {
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0"><dict>'
        [ -z "$API_KEY_XML" ] || printf '%s\n' "$API_KEY_XML"
        [ -z "$PROJECT_ID_XML" ] || printf '%s\n' "$PROJECT_ID_XML"
        [ -z "$SENDER_ID_XML" ] || printf '%s\n' "$SENDER_ID_XML"
        [ "$1" = "-" ] || printf '<key>GOOGLE_APP_ID</key><string>%s</string>\n' "$1"
        [ "$2" = "-" ] || printf '<key>BUNDLE_ID</key><string>%s</string>\n' "$2"
        printf '%s\n' '</dict></plist>'
    } >"$PLIST"
}

# begin <name>: a fresh case with a plist that is this app's and well formed.
begin() {
    CURRENT="$1"
    cases=$((cases + 1))
    CASE_DIR=$(mktemp -d "$WORK/case.XXXXXX")
    PLIST="$CASE_DIR/GoogleService-Info.plist"
    reset_other_keys
    write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL  %s: %s\n' "$CURRENT" "$1"
    printf '%s\n' "$OUT" | sed 's/^/        | /'
}

# run [arguments]: OUT holds everything the guard printed, STATUS its exit status. With no arguments the guard is given
# the case's plist and this app's bundle id. Whatever the case, the guard must neither print a value of the plist nor
# change the file.
run() {
    if [ "$#" -eq 0 ]; then
        set -- --plist "$PLIST" --bundle-id "$APP_BUNDLE"
    fi
    rm -f "$CASE_DIR/plist.before"
    if [ -f "$PLIST" ]; then
        cp "$PLIST" "$CASE_DIR/plist.before"
    fi
    OUT=$(sh "$GUARD" "$@" 2>&1)
    STATUS=$?
    case "$OUT" in
    *"$MARKER"* | *"$PROJECT_NUMBER"* | *"$PROJECT_NAME"*) fail "the output holds a value of the plist" ;;
    esac
    if [ -f "$CASE_DIR/plist.before" ] && ! cmp -s "$PLIST" "$CASE_DIR/plist.before"; then
        fail "the guard changed the plist"
    fi
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

# expect_no_text <text>: the output does not hold it.
expect_no_text() {
    case "$OUT" in
    *"$1"*) fail "expected the output not to contain: $1" ;;
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

# wrong_app_id <what is wrong> <GOOGLE_APP_ID>: a case for an app id that the SDK would raise on, or that is not an iOS
# app's.
wrong_app_id() {
    begin "fails when GOOGLE_APP_ID is $1"
    write_plist "$2" "$APP_BUNDLE"
    run
    expect_failure "GOOGLE_APP_ID"
}

begin "passes with a plist of this app"
run
expect_status 0
expect_text "firebase plist ok: $APP_BUNDLE"

begin "fails when the plist is missing"
rm -f "$PLIST"
run
expect_failure "does not exist"

begin "fails when the file is not a plist"
printf '\000\001not a plist at all\377\n' >"$PLIST"
run
expect_failure "not a property list"

begin "fails when the file is empty"
: >"$PLIST"
run
expect_failure "not a property list"

begin "fails when the plist is an array, not a dictionary"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><array><string>a</string><string>b</string></array></plist>' >"$PLIST"
run
expect_failure "GOOGLE_APP_ID"

begin "fails when GOOGLE_APP_ID is missing"
write_plist "-" "$APP_BUNDLE"
run
expect_failure "GOOGLE_APP_ID"

wrong_app_id "an Android app's" "1:${PROJECT_NUMBER}:android:0123456789abcdef"
wrong_app_id "missing its hash" "1:${PROJECT_NUMBER}:ios:"
wrong_app_id "not hex" "1:${PROJECT_NUMBER}:ios:xyz"
wrong_app_id "of version 2" "2:${PROJECT_NUMBER}:ios:0123456789abcdef"
wrong_app_id "given an extra part" "${GOOD_APP_ID}:extra"
wrong_app_id "given a project that is not a number" "1:abc:ios:0123456789abcdef"
wrong_app_id "given a space in front" " ${GOOD_APP_ID}"
wrong_app_id "empty" ""
# grep matches by line, and a command substitution drops line breaks at the end: a check that took the first line of
# these values, or lost the break, would accept them. The SDK's own reading would not.
wrong_app_id "given a second line" "${GOOD_APP_ID}
second line"
wrong_app_id "followed by a line break" "${GOOD_APP_ID}
"

begin "fails when BUNDLE_ID is another app's"
write_plist "$GOOD_APP_ID" "$OTHER_BUNDLE"
run
expect_failure "BUNDLE_ID"
expect_text "$APP_BUNDLE"
expect_no_text "$OTHER_BUNDLE"

begin "fails when BUNDLE_ID is missing"
write_plist "$GOOD_APP_ID" "-"
run
expect_failure "BUNDLE_ID"

begin "reports a wrong bundle and a wrong app id together, as two error lines"
write_plist "1:${PROJECT_NUMBER}:android:abc" "$OTHER_BUNDLE"
run
expect_failure "GOOGLE_APP_ID"
expect_text "BUNDLE_ID"
error_lines=$(printf '%s\n' "$OUT" | grep -c '^error: ')
[ "$error_lines" = 2 ] || fail "expected exactly two error lines, got $error_lines"

# The other keys the SDK raises an exception without, while it starts (Installations and Remote Config validate them).
# The first run of the app with a fixture plist crashed on a placeholder API_KEY that only the app id check had let by.
begin "passes with an API_KEY of the real shape (AIza, then 35 characters)"
API_KEY_XML="<key>API_KEY</key><string>AIza$(printf '%035d' 0)</string>"
write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
run
expect_status 0
expect_text "firebase plist ok: $APP_BUNDLE"

begin "fails when API_KEY is missing"
API_KEY_XML=""
write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
run
expect_failure "API_KEY"

# wrong_api_key <what is wrong> <API_KEY value>: a key that Installations raises on (or that is not ASCII, which the
# guard turns away because every key from the console is).
wrong_api_key() {
    begin "fails when API_KEY is $1"
    API_KEY_XML="<key>API_KEY</key><string>$2</string>"
    write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
    run
    expect_failure "API_KEY"
}

wrong_api_key "empty" ""
wrong_api_key "one character short" "${MARKER%?}"
wrong_api_key "one character long" "${MARKER}0"
wrong_api_key "not starting with an A" "B${MARKER#A}"
wrong_api_key "given a character that is no letter, digit, - or _" "${MARKER%?}!"
wrong_api_key "given a space" "A ${MARKER#A?}"
wrong_api_key "given a second line" "${MARKER}
second line"
wrong_api_key "given a letter that is not ASCII" "A$(printf '\303\251')${MARKER#A?}"
wrong_api_key "the placeholder that crashed the first run of the app" "FIXTURE-NOT-A-KEY"

begin "fails when API_KEY is a number, not text"
API_KEY_XML="<key>API_KEY</key><integer>5</integer>"
write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
run
expect_failure "API_KEY"

# wrong_text_key <what is wrong> <key> <xml>: PROJECT_ID or GCM_SENDER_ID, which the SDK reads as text and raises on
# when it is empty.
wrong_text_key() {
    begin "fails when $2 is $1"
    case "$2" in
    PROJECT_ID) PROJECT_ID_XML=$3 ;;
    GCM_SENDER_ID) SENDER_ID_XML=$3 ;;
    esac
    write_plist "$GOOD_APP_ID" "$APP_BUNDLE"
    run
    expect_failure "$2"
}

wrong_text_key "missing" PROJECT_ID ""
wrong_text_key "empty" PROJECT_ID "<key>PROJECT_ID</key><string></string>"
wrong_text_key "blank" PROJECT_ID "<key>PROJECT_ID</key><string>   </string>"
wrong_text_key "a number, not text" PROJECT_ID "<key>PROJECT_ID</key><integer>5</integer>"
wrong_text_key "missing" GCM_SENDER_ID ""
wrong_text_key "empty" GCM_SENDER_ID "<key>GCM_SENDER_ID</key><string></string>"
wrong_text_key "blank" GCM_SENDER_ID "<key>GCM_SENDER_ID</key><string>   </string>"
wrong_text_key "a number, not text" GCM_SENDER_ID "<key>GCM_SENDER_ID</key><integer>5</integer>"

begin "reports every key it cannot accept, one error line each"
API_KEY_XML="<key>API_KEY</key><string>FIXTURE-NOT-A-KEY</string>"
PROJECT_ID_XML=""
SENDER_ID_XML=""
write_plist "1:${PROJECT_NUMBER}:android:abc" "$OTHER_BUNDLE"
run
expect_failure "GOOGLE_APP_ID"
expect_text "API_KEY"
expect_text "PROJECT_ID"
expect_text "GCM_SENDER_ID"
expect_text "BUNDLE_ID"
error_lines=$(printf '%s\n' "$OUT" | grep -c '^error: ')
[ "$error_lines" = 5 ] || fail "expected exactly five error lines, got $error_lines"

begin "fails without --plist"
run --bundle-id "$APP_BUNDLE"
expect_failure "--plist is required"

begin "fails without --bundle-id"
run --plist "$PLIST"
expect_failure "--bundle-id is required"

begin "fails when an option has no value"
run --plist
expect_failure "--plist needs a value"

begin "fails with an unknown option"
run --plist "$PLIST" --bundle-id "$APP_BUNDLE" --verbose
expect_failure "unknown argument: --verbose"

if [ "$failures" -gt 0 ]; then
    printf 'check-firebase-plist: %s expectation checks failed, in the %s cases\n' "$failures" "$cases"
    exit 1
fi
printf 'check-firebase-plist: all %s cases passed\n' "$cases"
