#!/bin/sh
#
# Tests for Scripts/find-plain-strings.py.
#
# Every case builds a tiny fake source tree in a temporary folder, runs the scan on it and looks at what it printed.
# Run it from anywhere:
#
#     sh Marauders-ios/Scripts/tests/find-plain-strings-tests.sh
#
# It prints every failed expectation with the scan's output and exits 1 when anything failed.

HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="$HERE/../find-plain-strings.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/find-plain-strings-tests.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

cases=0
failures=0
CURRENT=""

# begin <name>: a fresh base folder with an empty Marauders/ tree and an empty allowlist.
begin() {
    CURRENT="$1"
    cases=$((cases + 1))
    BASE=$(mktemp -d "$WORK/case.XXXXXX")
    ALLOWLIST="$BASE/allowlist.txt"
    mkdir -p "$BASE/Marauders"
    : >"$ALLOWLIST"
}

# put <path under the base folder>: writes the file, its body comes from stdin.
put() {
    mkdir -p "$BASE/$(dirname "$1")"
    cat >"$BASE/$1"
}

# allow <line>: adds one line to the allowlist.
allow() {
    printf '%s\n' "$1" >>"$ALLOWLIST"
}

# run: OUT holds everything the scan printed, STATUS its exit status.
run() {
    OUT=$(python3 "$SCAN" --base "$BASE" --allowlist "$ALLOWLIST" 2>&1)
    STATUS=$?
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL  %s: %s\n' "$CURRENT" "$1"
    printf '%s\n' "$OUT" | sed 's/^/        | /'
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

# expect_order <first> <second>: both are in the output, the first one earlier.
expect_order() {
    case "$OUT" in
    *"$1"*"$2"*) ;;
    *) fail "expected \"$1\" before \"$2\"" ;;
    esac
}

# expect_hits <n>: exactly n reported literals.
expect_hits() {
    found=$(printf '%s\n' "$OUT" | grep -c '\.swift:[0-9][0-9]*: "')
    [ "$found" = "$1" ] || fail "expected $1 hit(s), got $found"
}

# expect_status <n>: the scan's exit status.
expect_status() {
    [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS"
}

# expect_clean: nothing reported, the OK line, exit status 0.
expect_clean() {
    expect_hits 0
    expect_text "OK: no plain strings"
    expect_status 0
}

# --- what is reported ----------------------------------------------------------------------------------------------

begin "a plain message is reported with its file and line"
put Marauders/Presentation/Upload/UploadViewModel.swift <<'EOF'
import Foundation

final class UploadViewModel {
    var status = "Sign in required"
}
EOF
run
expect_status 1
expect_hits 1
expect_text 'Marauders/Presentation/Upload/UploadViewModel.swift:4: "Sign in required"'
expect_text "1 plain strings"

begin "a text that starts with an acronym is reported"
put Marauders/Presentation/Feed/Engine.swift <<'EOF'
let message = "URL is not secure"
EOF
run
expect_status 1
expect_hits 1
expect_text 'Marauders/Presentation/Feed/Engine.swift:1: "URL is not secure"'

begin "one capitalised word is reported"
put Marauders/Presentation/Upload/Status.swift <<'EOF'
let title = "Download"
let busy = "Finishing…"
EOF
run
expect_hits 2
expect_text ':1: "Download"'
expect_text ':2: "Finishing…"'

begin "a word with an ellipsis is text, whatever follows it"
put Marauders/Presentation/Upload/Progress.swift <<'EOF'
struct Progress {
    let percent: Int
    var text: String { "Uploading… \(percent)%" }
}
EOF
run
expect_hits 1
expect_text ':3: "Uploading… \(percent)%"'

begin "a title of capitalised words is reported"
put Marauders/Presentation/Settings/Titles.swift <<'EOF'
let retry = "Try Again"
let place = "Clip Location"
EOF
run
expect_hits 2
expect_text ':1: "Try Again"'
expect_text ':2: "Clip Location"'

begin "a text that starts with a placeholder is reported as it is written"
put Marauders/Presentation/Map/NearMeRadius.swift <<'EOF'
struct NearMeRadius {
    let kilometers: Int
    var label: String { "\(kilometers) km" }
    var emptyClipsMessage: String { "No clips within \(kilometers) km" }
}
EOF
run
expect_hits 2
expect_text ':3: "\(kilometers) km"'
expect_text ':4: "No clips within \(kilometers) km"'

begin "a format string is reported"
put Marauders/Presentation/Map/Proximity.swift <<'EOF'
import Foundation

func formattedDistance(_ meters: Double) -> String {
    String(format: "%.0f m away", meters)
}
EOF
run
expect_hits 1
expect_text ':4: "%.0f m away"'

begin "a fallback after ?? is reported, also inside Text"
put Marauders/Presentation/Profile/ProfileView.swift <<'EOF'
import SwiftUI

final class ProfileModel {
    var message: String?
    var shown: String { message ?? "Could not load" }
}

struct ProfileView: View {
    let caption: String?
    var body: some View { Text(caption ?? "No caption yet") }
}
EOF
run
expect_hits 2
expect_text ':5: "Could not load"'
expect_text ':10: "No caption yet"'

begin "verbatim text is reported"
put Marauders/Presentation/Feed/Banner.swift <<'EOF'
import SwiftUI

struct Banner: View {
    var body: some View { Text(verbatim: "Sign in required") }
}
EOF
run
expect_hits 1
expect_text ':4: "Sign in required"'

begin "a conditional that mixes a literal with a variable is reported"
put Marauders/Presentation/Map/SharingRow.swift <<'EOF'
import SwiftUI

struct SharingRow: View {
    let flag: Bool
    let name: String
    var body: some View {
        VStack {
            Text(flag ? "Sharing is on" : name)
            Text(flag ? name : "Sharing is off")
        }
    }
}
EOF
run
expect_hits 2
expect_text ':8: "Sharing is on"'
expect_text ':9: "Sharing is off"'

begin "a literal in a closure is not an argument of the call around it"
put Marauders/Presentation/Feed/ReloadButton.swift <<'EOF'
import SwiftUI

struct ReloadButton: View {
    @State private var status = ""
    var body: some View {
        VStack {
            Button(action: { status = "Loading failed here" }) {
                Text("Load again")
            }
            Button("Load again") {
                status = "Loading failed again"
            }
        }
    }
}
EOF
run
expect_hits 2
expect_text ':7: "Loading failed here"'
expect_text ':11: "Loading failed again"'

begin "literals in an array are not arguments of the call around it"
put Marauders/Presentation/Map/SharingLabel.swift <<'EOF'
import SwiftUI

struct SharingLabel: View {
    let index: Int
    var body: some View { Text(["Sharing is on", "Sharing is off"][index]) }
}
EOF
run
expect_hits 2

begin "literals inside an interpolation are read on their own"
put Marauders/Presentation/Map/SharingText.swift <<'EOF'
let flag = true
let text = "\(flag ? "Sharing is on" : "Sharing is off") now"
EOF
run
expect_status 1
expect_no_text "Traceback"
expect_hits 3
expect_text ':2: "Sharing is on"'
expect_text ':2: "Sharing is off"'

begin "an escaped quote does not end the literal"
put Marauders/Presentation/Feed/Quote.swift <<'EOF'
let first = "Say \"hello there\" now"
let second = "Sign in required"
EOF
run
expect_hits 2
expect_text ':1: "Say \"hello there\" now"'
expect_text ':2: "Sign in required"'

begin "hits are sorted by file and line, then counted"
put Marauders/Presentation/B.swift <<'EOF'
let b = "Sign in required"
EOF
put Marauders/Domain/A.swift <<'EOF'
let first = "Upload failed today"

let second = "Could not load"
EOF
run
expect_status 1
expect_hits 3
expect_order 'Marauders/Domain/A.swift:1: "Upload failed today"' 'Marauders/Domain/A.swift:3: "Could not load"'
expect_order 'Marauders/Domain/A.swift:3: "Could not load"' 'Marauders/Presentation/B.swift:1: "Sign in required"'
expect_text "3 plain strings"

begin "the session package is scanned, other folders are not"
put Packages/MaraudersAuth/Sources/MaraudersAuth/SignInError.swift <<'EOF'
let description = "Invalid account"
EOF
put Packages/Other/Sources/Other/Thing.swift <<'EOF'
let description = "Sign in required"
EOF
put MaraudersTests/SomeTests.swift <<'EOF'
let expected = "Sign in required"
EOF
run
expect_hits 1
expect_text 'Packages/MaraudersAuth/Sources/MaraudersAuth/SignInError.swift:1: "Invalid account"'

# --- what is not reported ------------------------------------------------------------------------------------------

begin "literals that SwiftUI localizes are not reported"
put Marauders/Presentation/Settings/SettingsView.swift <<'EOF'
import SwiftUI

struct SettingsView: View {
    @State private var shown = false
    @State private var query = ""

    var body: some View {
        List {
            Section("Listening language") {
                Text("Sign in required")
                Button("Retry") {}
                Label("Open the map", systemImage: "map")
                Toggle("Share my location", isOn: $shown)
                TextField("Search clips", text: $query, prompt: Text("Find a place"))
                LabeledContent("App language") { Text("English only") }
            }
        }
        .navigationTitle("Settings")
        .accessibilityLabel("Open the settings")
        .searchable(text: $query, prompt: "Search clips")
        .alert("Could not load", isPresented: $shown) {
            Button("Try Again") {}
        } message: {
            Text("Check your connection")
        }
    }
}
EOF
run
expect_clean

begin "a conditional of two literals is localized by SwiftUI"
put Marauders/Presentation/Map/SharingRow.swift <<'EOF'
import SwiftUI

struct SharingRow: View {
    let flag: Bool
    var body: some View {
        VStack {
            Text(flag ? "Sharing is on" : "Sharing is off")
            Button(flag ? "Stop sharing" : "Start sharing") {}
            Label(
                flag ? "Sharing is on" : "Sharing is off",
                systemImage: flag ? "location.fill" : "location")
        }
    }
}
EOF
run
expect_clean

begin "String(localized:) is localized, on one line or two"
put Marauders/Domain/UploadError.swift <<'EOF'
import Foundation

struct UploadError {
    let percent: Int
    var one: String { String(localized: "Sign in required") }
    var two: String {
        String(
            localized:
                "The upload was interrupted. Try again.")
    }
    var three: String { String(localized: "Uploading… \(percent)%") }
    var four = LocalizedStringResource("Sign in required")
}
EOF
run
expect_clean

begin "codes, identifiers and names are not text"
put Marauders/Shared/Names.swift <<'EOF'
enum Names {
    static let ok = "OK"
    static let country = "TH"
    static let method = "GET"
    static let flag = "UITEST"
    static let model = "MelSpectrogram"
    static let ext = "mp4"
    static let id = "settings.root"
    static let mime = "video/mp4"
    static let key = "upload_record_v2"
    static let empty = ""
    static let format = "%d"
    static let prefix = "Bearer "
    static let font = "SF Pro"
    static func header(_ token: String) -> String { "Bearer \(token)" }
}
EOF
run
expect_clean

begin "logging, assertions, identifiers and URLs are not text for the viewer"
put Marauders/Data/Worker.swift <<'EOF'
import SwiftUI

func work(ready: Bool, count: Int) {
    AppLog.info("upload", "Upload finished here")
    AppLog.warning("upload", "Upload failed after \(count) tries")
    print("Startup cache was read")
    assert(ready, "Bad state here")
    precondition(ready, "Bad state here")
    if count < 0 { assertionFailure("Bad state here") }
    if count < -1 { preconditionFailure("Bad state here") }
    if count < -2 { fatalError("Bad state here") }
    let url = URL(string: "Https://example.com/some path here")
    let request = URLRequest(url: URL(fileURLWithPath: "Some file path here"))
    _ = (url, request)
}

struct Row: View {
    var body: some View { Text("Feed").accessibilityIdentifier("Some id here") }
}
EOF
run
expect_clean

begin "arguments behind labels that never hold text are not reported"
put Marauders/Data/Setup.swift <<'EOF'
import SwiftUI

func setUp(request: inout URLRequest, defaults: UserDefaults, token: String) {
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let logger = Logger(subsystem: "Marauders", category: "Upload")
    let stored = defaults.string(forKey: "Selected")
    let image = Image(systemName: "Globe")
    let asset = UIImage(named: "Avatar")
    let item = Item(id: "Settings", identifier: "Profile")
    _ = (logger, stored, image, asset, item)
}
EOF
run
expect_clean

begin "comments and previews are skipped"
put Marauders/Presentation/Feed/FeedRow.swift <<'EOF'
import SwiftUI

// let message = "Sign in required"
/* let message = "Sign in required"
   /* nested "Sign in required" */
   still a comment "Sign in required" */
struct FeedRow: View {
    var body: some View { Text("Feed") } // "Sign in required"
}

#Preview("Sign in sheet") {
    let sample = "Hello there world"
    return FeedRow().environment(\.note, sample)
}

#Preview {
    FeedRow().environment(\.note, "Hello there world")
}
EOF
run
expect_clean

begin "a multi-line literal is skipped and the lines after it keep their numbers"
put Marauders/Presentation/Help.swift <<'EOF'
let help = """
    Sign in required
    "Quoted line here"
    """
let after = "Sign in required"
EOF
run
expect_hits 1
expect_text 'Marauders/Presentation/Help.swift:5: "Sign in required"'

begin "a raw string is skipped"
put Marauders/Data/Pattern.swift <<'EOF'
let pattern = #"^Sign in \d+ times "quoted" here"#
let after = "Sign in required"
EOF
run
expect_hits 1
expect_text 'Marauders/Data/Pattern.swift:2: "Sign in required"'

begin "a tree with nothing to report is OK"
put Marauders/App.swift <<'EOF'
import SwiftUI

@main
struct MaraudersApp: App {
    var body: some Scene { WindowGroup { Text("Feed") } }
}
EOF
run
expect_clean

begin "an empty tree is OK"
run
expect_clean

# --- the allowlist -------------------------------------------------------------------------------------------------

begin "an allowlist line hides one text of one file"
put Marauders/Shared/Background.swift <<'EOF'
let reason = "Share location"
let other = "Sign in required"
EOF
allow 'Marauders/Shared/Background.swift|Share location  # the name of a background task, never shown'
run
expect_status 1
expect_hits 1
expect_no_text '"Share location"'
expect_text ':2: "Sign in required"'

begin "comment lines and empty lines of the allowlist are ignored"
put Marauders/Shared/Background.swift <<'EOF'
let reason = "Share location"
EOF
allow '# developer-only texts'
allow ''
allow 'Marauders/Shared/Background.swift|Share location  # the name of a background task, never shown'
run
expect_clean

begin "an allowlist line without a reason works too"
put Marauders/Shared/Background.swift <<'EOF'
let reason = "Share location"
EOF
allow 'Marauders/Shared/Background.swift|Share location'
run
expect_clean

begin "an allowlist line hides the text in its own file only"
put Marauders/Shared/Background.swift <<'EOF'
let reason = "Share location"
EOF
put Marauders/Presentation/Map/MapModel.swift <<'EOF'
let title = "Share location"
EOF
allow 'Marauders/Shared/Background.swift|Share location  # the name of a background task, never shown'
run
expect_status 1
expect_hits 1
expect_text 'Marauders/Presentation/Map/MapModel.swift:1: "Share location"'

begin "an allowlist line with * hides a whole file"
put Marauders/Data/Repositories/UITestFeedRepository.swift <<'EOF'
let caption = "UI test clip"
let other = "Streaming test clip \(1)"
EOF
allow 'Marauders/Data/Repositories/UITestFeedRepository.swift|*  # fixtures of the UI tests'
run
expect_clean

begin "an allowlisted text with a placeholder is matched as it is written"
put Marauders/Data/Repositories/UITestFeedRepository.swift <<'EOF'
let other = "Streaming test clip \(index)"
EOF
allow 'Marauders/Data/Repositories/UITestFeedRepository.swift|Streaming test clip \(index)  # a fixture'
run
expect_clean

# --- result --------------------------------------------------------------------------------------------------------

if [ "$failures" -eq 0 ]; then
    echo "find-plain-strings: all $cases cases passed"
    exit 0
fi
echo "find-plain-strings: $failures expectation(s) failed in $cases cases"
exit 1
