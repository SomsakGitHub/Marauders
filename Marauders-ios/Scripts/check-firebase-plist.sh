#!/bin/sh
#
# The Firebase plist guard (docs/adr/012-force-update.md): the TestFlight lane runs it, on the plist that Jenkins handed
# over, before it builds. A build whose plist is missing, is another app's or holds keys the SDK cannot start from has
# a force-update gate that never reads the minimum, and nothing else would say so: the app starts and runs as it did
# before the gate. The guard checks the file that will be bundled, not what Jenkins is set up to hold.
#
#     sh Scripts/check-firebase-plist.sh --plist <GoogleService-Info.plist> --bundle-id <the app's bundle id>
#
# Exit 0 and "firebase plist ok: <bundle id>" only when
#   - the file exists and is a property list,
#   - GOOGLE_APP_ID in it has the shape of an iOS app's id, 1:<project number>:ios:<hex digits>, all of it,
#   - API_KEY in it is what the SDK's Installations demands of a key: 39 characters, an A first, then letters, digits,
#     - and _ (every key from the console is ASCII, so this is a little stricter than the SDK),
#   - PROJECT_ID and GCM_SENDER_ID in it are text that is not blank, and
#   - BUNDLE_ID in it is the bundle id given.
# Each of the first four is what FirebasePlistCheck accepts at run time, and what the SDK raises an exception without
# (the first run of the app with a placeholder API_KEY crashed it), so a file this guard passes cannot crash the app. A
# key of any other type than text counts as missing, as the app counts it.
# Every failure prints one or more lines that start with "error: " (as check-release-config.sh does, so that a build
# log lists them) and exits 1. The guard fails closed: a file or a key it cannot read is a failure, never a pass. It
# reads the file and prints; it changes nothing. It never prints a value of the plist, because the output of a build
# reaches a log that more people read than the plist: only the names of the keys and the bundle id it was given.

NEWLINE='
'

problems=0

usage_error() {
    printf 'error: %s\n' "$1"
    printf 'error: usage: check-firebase-plist.sh --plist <GoogleService-Info.plist> --bundle-id <bundle id>\n'
    exit 1
}

problem() {
    printf 'error: %s\n' "$1"
    problems=$((problems + 1))
}

plist=""
bundle_id=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --plist | --bundle-id)
        [ "$#" -ge 2 ] || usage_error "$1 needs a value"
        case "$1" in
        --plist) plist=$2 ;;
        --bundle-id) bundle_id=$2 ;;
        esac
        shift 2
        ;;
    *) usage_error "unknown argument: $1" ;;
    esac
done
[ -n "$plist" ] || usage_error "--plist is required"
[ -n "$bundle_id" ] || usage_error "--bundle-id is required"

if [ ! -f "$plist" ]; then
    problem "the plist $plist does not exist"
    exit 1
fi
if ! plutil -lint "$plist" >/dev/null 2>&1; then
    problem "the file $plist is not a property list"
    exit 1
fi

# read_key <key>: VALUE becomes what the plist holds under <key> at its top, or nothing when it cannot be read or is not
# text (the SDK reads these keys as text: a number there fails it later, in a way this guard could not see). A command
# substitution would drop line breaks at the end of a value, which the SDK would not: the sentinel keeps them, and the
# one line break that plutil itself prints after a value is taken off.
read_key() {
    VALUE=""
    [ "$(plutil -type "$1" "$plist" 2>/dev/null)" = "string" ] || return 0
    VALUE=$(
        plutil -extract "$1" raw -o - "$plist" 2>/dev/null
        printf x
    )
    VALUE=${VALUE%x}
    VALUE=${VALUE%"$NEWLINE"}
}

# is_ios_app_id <text>: 1:<digits>:ios:<hex digits>, all of it. grep judges line by line, so a value of several lines is
# turned away first.
is_ios_app_id() {
    case "$1" in
    *"$NEWLINE"*) return 1 ;;
    esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eqx '1:[0-9]+:ios:[0-9a-fA-F]+'
}

# is_api_key <text>: an A, then 38 of A-Z a-z 0-9 - _, all of it (a real key is AIza and 35 more). A value of several lines
# is turned away first, as above.
is_api_key() {
    case "$1" in
    *"$NEWLINE"*) return 1 ;;
    esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eqx 'A[A-Za-z0-9_-]{38}'
}

# is_filled <text>: something that is not only white space.
is_filled() {
    printf '%s\n' "$1" | LC_ALL=C grep -q '[^[:space:]]'
}

read_key GOOGLE_APP_ID
if [ -z "$VALUE" ]; then
    problem "the plist $plist has no readable GOOGLE_APP_ID: Firebase cannot start without it"
elif ! is_ios_app_id "$VALUE"; then
    problem "GOOGLE_APP_ID in the plist $plist is not the id of an iOS app (1:<project number>:ios:<hex digits>): it is not the plist of this app, or it is damaged"
fi

read_key API_KEY
if [ -z "$VALUE" ]; then
    problem "the plist $plist has no readable API_KEY: Firebase cannot start without it"
elif ! is_api_key "$VALUE"; then
    problem "API_KEY in the plist $plist is not shaped like a Firebase API key (39 characters: an A, then letters, digits, - and _): it is damaged, or a placeholder"
fi

read_key PROJECT_ID
if [ -z "$VALUE" ] || ! is_filled "$VALUE"; then
    problem "the plist $plist has no readable PROJECT_ID: Firebase cannot start without it"
fi

read_key GCM_SENDER_ID
if [ -z "$VALUE" ] || ! is_filled "$VALUE"; then
    problem "the plist $plist has no readable GCM_SENDER_ID: Remote Config cannot start without it"
fi

read_key BUNDLE_ID
if [ -z "$VALUE" ]; then
    problem "the plist $plist has no readable BUNDLE_ID: it cannot be told whose plist it is"
elif [ "$VALUE" != "$bundle_id" ]; then
    problem "the plist $plist is another app's: its BUNDLE_ID is not $bundle_id"
fi

if [ "$problems" -gt 0 ]; then
    exit 1
fi
printf 'firebase plist ok: %s\n' "$bundle_id"
