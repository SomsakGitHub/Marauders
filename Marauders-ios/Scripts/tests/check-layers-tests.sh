#!/bin/sh
#
# Tests for Scripts/check-layers.sh.
#
# Every case builds a tiny fake Marauders/ source tree in a temporary folder, runs the checker on it and looks at what
# it printed. Run it from anywhere:
#
#     sh Marauders-ios/Scripts/tests/check-layers-tests.sh
#
# It prints every failed expectation with the checker's output and exits 1 when anything failed.

HERE=$(cd "$(dirname "$0")" && pwd)
CHECKER="$HERE/../check-layers.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-layers-tests.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

cases=0
failures=0
CURRENT=""

# begin <name>: a fresh fake source tree, an empty exceptions file and an empty list of module folders.
begin() {
    CURRENT="$1"
    cases=$((cases + 1))
    CASE_DIR=$(mktemp -d "$WORK/case.XXXXXX")
    ROOT="$CASE_DIR/Marauders"
    EXCEPTIONS="$CASE_DIR/exceptions.txt"
    MODULES="$CASE_DIR/modules.txt"
    mkdir -p "$ROOT"
    : >"$EXCEPTIONS"
    : >"$MODULES"
}

# put <path under Marauders/>: writes the file, its body comes from stdin.
put() {
    mkdir -p "$ROOT/$(dirname "$1")"
    cat >"$ROOT/$1"
}

# run [checker options]: OUT holds everything the checker printed, STATUS its exit status.
run() {
    OUT=$(sh "$CHECKER" --root "$ROOT" --exceptions "$EXCEPTIONS" --modules "$MODULES" "$@" 2>&1)
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

# expect_warnings <n>: exactly n layer warnings.
expect_warnings() {
    found=$(printf '%s\n' "$OUT" | grep -c ': warning: \[layer\]')
    [ "$found" = "$1" ] || fail "expected $1 warning(s), got $found"
}

# expect_status <n>: the checker's exit status.
expect_status() {
    [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS"
}

# base_tree: a small tree that follows every rule: Domain depends on nothing, Data implements a Domain protocol and
# logs through Shared, Presentation reaches Domain through a use case, Composition and App wire everything.
base_tree() {
    put Domain/Entities/Clip.swift <<'EOF'
import Foundation

struct Clip {
    let id: String
}
EOF
    put Domain/Repositories/ClipRepository.swift <<'EOF'
import Foundation

protocol ClipRepository {
    func clips() async throws -> [Clip]
}
EOF
    put Domain/UseCases/FetchClipsUseCase.swift <<'EOF'
import Foundation

struct FetchClipsUseCase {
    let repository: ClipRepository
}
EOF
    put Data/Repositories/DefaultClipRepository.swift <<'EOF'
import UIKit

struct DefaultClipRepository: ClipRepository {
    func clips() async throws -> [Clip] {
        AppLog.info("clips", "load")
        return []
    }
}
EOF
    put Shared/Logging/AppLog.swift <<'EOF'
import Foundation

enum AppLog {
    static func info(_ category: String, _ message: String) {}
}
EOF
    put Presentation/Feed/ClipListViewModel.swift <<'EOF'
import Foundation

@MainActor
@Observable
final class ClipListViewModel {
    let fetch: FetchClipsUseCase
    init(fetch: FetchClipsUseCase) { self.fetch = fetch }
}
EOF
    put Presentation/Feed/ClipListView.swift <<'EOF'
import SwiftUI

struct ClipListView: View {
    let viewModel: ClipListViewModel
    var body: some View { Text("clips") }
}
EOF
    put Presentation/Map/LocationReporter.swift <<'EOF'
import Foundation

struct LocationReporter {
    let fetch: FetchClipsUseCase
}
EOF
    put Composition/AppDependencyContainer.swift <<'EOF'
import Foundation

final class AppDependencyContainer {
    let viewModel = ClipListViewModel(fetch: FetchClipsUseCase(repository: DefaultClipRepository()))
}
EOF
    put App/MaraudersApp.swift <<'EOF'
import SwiftUI

struct MaraudersApp {
    let container = AppDependencyContainer()
}
EOF
}

# --- a tree that follows the rules -------------------------------------------------------------------------------

begin "a tree that follows the rules prints nothing"
base_tree
run
expect_warnings 0
expect_status 0
[ -z "$OUT" ] || fail "expected no output at all"

# --- imports -----------------------------------------------------------------------------------------------------

begin "Domain may import Foundation only"
base_tree
put Domain/Entities/Clip.swift <<'EOF'
import Foundation
import SwiftUI
import CoreLocation

struct Clip {
    let id: String
}
EOF
run
expect_text "Domain/Entities/Clip.swift:2: warning: [layer] Domain imports 'SwiftUI'; Domain may import Foundation only"
expect_text "Domain/Entities/Clip.swift:3: warning: [layer] Domain imports 'CoreLocation'; Domain may import Foundation only"
expect_warnings 2

begin "Data may import UIKit but not SwiftUI"
base_tree
put Data/Repositories/DefaultClipRepository.swift <<'EOF'
import UIKit
import SwiftUI

struct DefaultClipRepository: ClipRepository {
    func clips() async throws -> [Clip] { [] }
}
EOF
run
expect_text "DefaultClipRepository.swift:2: warning: [layer] Data imports 'SwiftUI'; Data must not import SwiftUI"
expect_warnings 1

begin "Shared imports no UI framework"
base_tree
put Shared/Logging/AppLog.swift <<'EOF'
import UIKit

enum AppLog {
    static func info(_ category: String, _ message: String) {}
}
EOF
run
expect_text "AppLog.swift:1: warning: [layer] Shared imports 'UIKit'; Shared must not import UI frameworks"
expect_warnings 1

# --- type references ---------------------------------------------------------------------------------------------

begin "Domain must not name Data, Presentation or Shared types"
base_tree
put Domain/UseCases/FetchClipsUseCase.swift <<'EOF'
struct FetchClipsUseCase {
    let repository: ClipRepository
    let concrete: DefaultClipRepository
    let model: ClipListViewModel
    func log() { AppLog.info("clips", "load") }
}
EOF
run
expect_text "FetchClipsUseCase.swift:3: warning: [layer] Domain names Data type 'DefaultClipRepository'; Domain must not depend on Data"
expect_text "FetchClipsUseCase.swift:4: warning: [layer] Domain names Presentation type 'ClipListViewModel'; Domain must not depend on Presentation"
expect_text "FetchClipsUseCase.swift:5: warning: [layer] Domain names Shared type 'AppLog'; Domain must not depend on Shared"
expect_warnings 3

begin "Data must not name Presentation types"
base_tree
put Data/Services/Bridge.swift <<'EOF'
struct Bridge {
    let model: ClipListViewModel
}
EOF
run
expect_text "Bridge.swift:2: warning: [layer] Data names Presentation type 'ClipListViewModel'; Data must not depend on Presentation"
expect_warnings 1

begin "Presentation must not name Data types"
base_tree
put Presentation/Feed/ClipListViewModel.swift <<'EOF'
@MainActor
@Observable
final class ClipListViewModel {
    let fetch: FetchClipsUseCase
    let direct = DefaultClipRepository()
}
EOF
run
expect_text "ClipListViewModel.swift:5: warning: [layer] Presentation names Data type 'DefaultClipRepository'; Presentation must not depend on Data"
expect_warnings 1

begin "Views talk to ViewModels, not to use cases or repositories"
base_tree
put Presentation/Feed/ClipListView.swift <<'EOF'
import SwiftUI

struct ClipListView: View {
    let viewModel: ClipListViewModel
    let fetch: FetchClipsUseCase
    let repository: ClipRepository
    var body: some View { Text("clips") }
}
EOF
run
expect_text "ClipListView.swift:5: warning: [layer] View names Domain use case or repository 'FetchClipsUseCase'; Views talk to ViewModels"
expect_text "ClipListView.swift:6: warning: [layer] View names Domain use case or repository 'ClipRepository'; Views talk to ViewModels"
expect_warnings 2

begin "Shared must not name Domain types"
base_tree
put Shared/Logging/AppLog.swift <<'EOF'
import Foundation

enum AppLog {
    static func info(_ category: String, _ message: String, clip: Clip? = nil) {}
}
EOF
run
expect_text "AppLog.swift:4: warning: [layer] Shared names Domain type 'Clip'; Shared must not depend on Domain"
expect_warnings 1

# --- what the scanner has to ignore or understand ------------------------------------------------------------------

begin "comments and strings are ignored, and a string holding /* does not open a comment"
base_tree
put Data/Services/Notes.swift <<'EOF'
import Foundation

// ClipListViewModel in a line comment.
/// ClipListView in a doc comment.
/* ClipListViewModel in a block comment
   that goes on for a second line, ClipListView again */
struct Notes {
    let text = "ClipListViewModel in a string"
    let url = "https://example.com/ClipListView" // ClipListViewModel in a trailing comment
    let glob = "images/*"
    let bad: ClipListViewModel? = nil
}
EOF
run
expect_text "Notes.swift:11: warning: [layer] Data names Presentation type 'ClipListViewModel'"
expect_warnings 1

begin "nested and private types never count as a layer's types"
base_tree
put Presentation/Feed/ClipLikes.swift <<'EOF'
private struct Entry {}

final class ClipLikes {
    struct Row {}
    private struct Cell {}
}
EOF
put Data/Services/Cache.swift <<'EOF'
struct Cache {
    private struct Entry: Codable {}
    var entries: [Entry] = []
    var rows: [Row] = []
    var cells: [Cell] = []
}
EOF
run
expect_warnings 0

begin "declarations inside a top-level #if block count, nested ones do not"
base_tree
put Presentation/Debug/DebugLogView.swift <<'EOF'
#if DEBUG
    import SwiftUI

    struct DebugLogView: View {
        struct Inner {}
        #if os(iOS)
            struct OnlyOnPhones {}
        #endif
        var body: some View { Text("log") }
    }
#endif

struct AfterTheBlock {}
EOF
put Data/Services/Peek.swift <<'EOF'
struct Peek {
    let view: DebugLogView
    let inner: Inner
    let phones: OnlyOnPhones
    let after: AfterTheBlock
}
EOF
run
expect_text "Peek.swift:2: warning: [layer] Data names Presentation type 'DebugLogView'"
expect_text "Peek.swift:5: warning: [layer] Data names Presentation type 'AfterTheBlock'"
expect_warnings 2

begin "code inside #Preview blocks is not checked, code between and after them is"
base_tree
put Data/Services/ClipCache.swift <<'EOF'
struct ClipCache {}
EOF
put Data/Services/ClipUploader.swift <<'EOF'
struct ClipUploader {}
EOF
put Presentation/Feed/ClipListView.swift <<'EOF'
import SwiftUI

struct ClipListView: View {
    let viewModel: ClipListViewModel
    var body: some View { Text("clips") }
}

#Preview("one line") { ClipListView(viewModel: ClipListViewModel(fetch: FetchClipsUseCase(repository: DefaultClipRepository()))) }

struct BetweenThePreviews: View {
    let cache = ClipCache()
    var body: some View { Text("between") }
}

#Preview {
    VStack {
        ClipListView(viewModel: ClipListViewModel(fetch: FetchClipsUseCase(repository: DefaultClipRepository())))
    }
    let uploader = ClipUploader()
    ClipListView(viewModel: ClipListViewModel(fetch: FetchClipsUseCase(repository: DefaultClipRepository())))
}

struct AfterThePreviews: View {
    let direct = DefaultClipRepository()
    var body: some View { Text("after") }
}
EOF
run
expect_text "ClipListView.swift:11: warning: [layer] Presentation names Data type 'ClipCache'"
expect_text "ClipListView.swift:24: warning: [layer] Presentation names Data type 'DefaultClipRepository'"
expect_no_text "'ClipUploader'"
expect_warnings 2

begin "an indented #Preview ends at its own closing brace"
base_tree
put Data/Services/ClipCache.swift <<'EOF'
struct ClipCache {}
EOF
put Presentation/Debug/DebugOnlyView.swift <<'EOF'
import SwiftUI

struct DebugOnlyView: View {
    var body: some View { Text("debug") }
}

#if DEBUG
    #Preview {
        VStack {
            Text("inside")
        }
        let repository = DefaultClipRepository()
    }
#endif

struct AfterTheDebugBlock: View {
    let cache = ClipCache()
    var body: some View { Text("after") }
}
EOF
run
expect_text "DebugOnlyView.swift:17: warning: [layer] Presentation names Data type 'ClipCache'"
expect_no_text "'DefaultClipRepository'"
expect_warnings 1

begin "a name declared at top level in two layers is skipped"
base_tree
put Presentation/Feed/Item.swift <<'EOF'
struct Item {}
EOF
put Shared/Item.swift <<'EOF'
struct Item {}
EOF
put Data/Services/UsesItem.swift <<'EOF'
struct UsesItem {
    let item: Item
}
EOF
run
expect_warnings 0

begin "a name is reported once per file, at its first line"
base_tree
put Data/Services/Bridge.swift <<'EOF'
struct Bridge {
    let first: ClipListViewModel
    let second: ClipListViewModel
}
EOF
run
expect_text "Bridge.swift:2: warning: [layer] Data names Presentation type 'ClipListViewModel'"
expect_warnings 1

# --- the exceptions list -------------------------------------------------------------------------------------------

begin "an exception silences exactly its file and name"
base_tree
put Domain/Entities/Clip.swift <<'EOF'
import Foundation
import SwiftUI

struct Clip {
    let id: String
}
EOF
put Domain/UseCases/FetchClipsUseCase.swift <<'EOF'
struct FetchClipsUseCase {
    let repository: ClipRepository
    let concrete: DefaultClipRepository
}
EOF
put Domain/UseCases/OtherUseCase.swift <<'EOF'
struct OtherUseCase {
    let concrete: DefaultClipRepository
}
EOF
cat >"$EXCEPTIONS" <<'EOF'
# accepted for now
Domain/Entities/Clip.swift: import SwiftUI   # a reason
Domain/UseCases/FetchClipsUseCase.swift: DefaultClipRepository  # another reason
EOF
run
expect_no_text "Entities/Clip.swift"
expect_no_text "FetchClipsUseCase.swift"
expect_text "OtherUseCase.swift:2: warning: [layer] Domain names Data type 'DefaultClipRepository'"
expect_warnings 1

begin "an exception that matches nothing is reported"
base_tree
cat >"$EXCEPTIONS" <<'EOF'
# header comment

Domain/Entities/Clip.swift: import SwiftUI   # no longer imported
EOF
run
expect_text "exceptions.txt:3: warning: [layer] unused exception 'Domain/Entities/Clip.swift: import SwiftUI'; remove it"
expect_warnings 1

begin "a missing exceptions file is fine"
base_tree
rm -f "$EXCEPTIONS"
run
expect_warnings 0
expect_status 0

# --- exit status and errors ----------------------------------------------------------------------------------------

begin "warnings leave the status at 0 unless --strict is given"
base_tree
put Data/Services/Bridge.swift <<'EOF'
struct Bridge {
    let model: ClipListViewModel
}
EOF
run
expect_status 0
expect_warnings 1
run --strict
expect_status 1

begin "--strict on a clean tree still exits 0"
base_tree
run --strict
expect_status 0

begin "a missing source folder is an error"
OUT=$(sh "$CHECKER" --root "$CASE_DIR/nope" 2>&1)
STATUS=$?
expect_status 2
expect_text "error: source folder not found"

# put_module <path under the case folder>: a file of a module folder, its body comes from stdin.
put_module() {
    mkdir -p "$CASE_DIR/$(dirname "$1")"
    cat >"$CASE_DIR/$1"
}

# auth_modules: the fake package the module cases use. Auth is more Domain, AuthData is more Data.
auth_modules() {
    cat >"$MODULES" <<'EOF'
# <Layer>: <folder, from the folder that holds Marauders/>
Domain: Packages/Auth/Sources/Auth
Data: Packages/Auth/Sources/AuthData
EOF
    put_module Packages/Auth/Sources/Auth/Tokens.swift <<'EOF'
import Foundation

public struct Tokens {
    public init() {}
}
EOF
    put_module Packages/Auth/Sources/AuthData/KeychainStore.swift <<'EOF'
import Auth
import Foundation
import Security

public struct KeychainStore {
    public init() {}
}
EOF
}

# --- module folders ----------------------------------------------------------------------------------------------

begin "a tree with module folders that follows the rules prints nothing"
base_tree
auth_modules
put Domain/UseCases/RevokeUseCase.swift <<'EOF'
import Auth
import Foundation

struct RevokeUseCase {
    let tokens: Tokens
}
EOF
put Data/Repositories/SessionRepository.swift <<'EOF'
import Auth
import AuthData
import Foundation

struct SessionRepository {
    let store = KeychainStore()
    let tokens: Tokens
}
EOF
put Composition/SessionWiring.swift <<'EOF'
import Auth
import AuthData
import Foundation

struct SessionWiring {
    let repository = SessionRepository(tokens: Tokens())
}
EOF
run --strict
expect_warnings 0
expect_status 0
[ -z "$OUT" ] || fail "expected no output at all"

begin "a type declared in a module folder belongs to that folder's layer"
base_tree
auth_modules
put_module Packages/Auth/Sources/Auth/SignInUseCase.swift <<'EOF'
import Foundation

public struct SignInUseCase {
    public init() {}
}
EOF
put Presentation/Auth/SignInViewModel.swift <<'EOF'
import Auth
import Foundation

final class SignInViewModel {
    let signIn = SignInUseCase()
    let store = KeychainStore()
}
EOF
put Presentation/Auth/SignInView.swift <<'EOF'
import Auth
import SwiftUI

struct SignInView: View {
    let signIn = SignInUseCase()
    var body: some View { Text("sign in") }
}
EOF
run
expect_text "Presentation/Auth/SignInViewModel.swift:6: warning: [layer] Presentation names Data type 'KeychainStore'; Presentation must not depend on Data"
expect_text "Presentation/Auth/SignInView.swift:5: warning: [layer] View names Domain use case or repository 'SignInUseCase'; Views talk to ViewModels"
expect_warnings 2

begin "the rules of a layer apply inside its module folder"
base_tree
auth_modules
put_module Packages/Auth/Sources/Auth/TokenRules.swift <<'EOF'
import Foundation
import Security

public enum TokenRules {
    static let repository = DefaultClipRepository()
}
EOF
put_module Packages/Auth/Sources/AuthData/KeychainStore.swift <<'EOF'
import Foundation
import SwiftUI

public struct KeychainStore {}
EOF
run
expect_text "Packages/Auth/Sources/Auth/TokenRules.swift:2: warning: [layer] Domain imports 'Security'; Domain may import Foundation only"
expect_text "Packages/Auth/Sources/Auth/TokenRules.swift:5: warning: [layer] Domain names Data type 'DefaultClipRepository'; Domain must not depend on Data"
expect_text "Packages/Auth/Sources/AuthData/KeychainStore.swift:2: warning: [layer] Data imports 'SwiftUI'; Data must not import SwiftUI"
expect_warnings 3

begin "importing a module is judged like naming a type of its layer"
base_tree
auth_modules
put Domain/UseCases/RevokeUseCase.swift <<'EOF'
import Auth
import AuthData
import Foundation

struct RevokeUseCase {}
EOF
put Presentation/Auth/SessionViewModel.swift <<'EOF'
import Auth
import AuthData
import Foundation

final class SessionViewModel {}
EOF
put Shared/Logging/AppLog.swift <<'EOF'
import Auth
import Foundation

enum AppLog {
    static func info(_ category: String, _ message: String) {}
}
EOF
run
expect_text "Domain/UseCases/RevokeUseCase.swift:2: warning: [layer] Domain imports 'AuthData'; Domain must not depend on Data"
expect_text "Presentation/Auth/SessionViewModel.swift:2: warning: [layer] Presentation imports 'AuthData'; Presentation must not depend on Data"
expect_text "Shared/Logging/AppLog.swift:1: warning: [layer] Shared imports 'Auth'; Shared must not depend on Domain"
expect_warnings 3

begin "an exception for a file in a module folder uses its path from the folder that holds Marauders/"
base_tree
auth_modules
put_module Packages/Auth/Sources/Auth/TokenHash.swift <<'EOF'
import CryptoKit
import Foundation

public enum TokenHash {}
EOF
echo "Packages/Auth/Sources/Auth/TokenHash.swift: import CryptoKit  # hashes the token" >"$EXCEPTIONS"
run
expect_warnings 0

begin "a module folder that is not there is an error, and so is a layer that does not exist"
base_tree
auth_modules
echo "Domain: Packages/Nowhere/Sources/Nowhere" >"$MODULES"
run
expect_status 2
expect_text "error: module folder not found"
echo "Network: Packages/Auth/Sources/Auth" >"$MODULES"
run
expect_status 2
expect_text "error: unknown layer"

begin "a missing modules file is fine"
base_tree
run --modules "$CASE_DIR/no-such-file.txt"
expect_warnings 0
expect_status 0

begin "a line of the modules file that is not '<Layer>: <folder>' is an error"
base_tree
auth_modules
echo "Domain Packages/Auth/Sources/Auth" >"$MODULES"
run
expect_status 2
expect_text "error: malformed line"

begin "a comment after the folder of a module line is not part of the folder"
base_tree
auth_modules
printf '%s\n' 'Domain: Packages/Auth/Sources/Auth  # the Domain half' \
    'Data: Packages/Auth/Sources/AuthData	# the Data half, after a tab' >"$MODULES"
put Presentation/Auth/SignInViewModel.swift <<'EOF'
import Foundation

final class SignInViewModel {
    let store = KeychainStore()
}
EOF
run
expect_status 0
expect_text "Presentation/Auth/SignInViewModel.swift:4: warning: [layer] Presentation names Data type 'KeychainStore'; Presentation must not depend on Data"
expect_warnings 1

# --- result --------------------------------------------------------------------------------------------------------

if [ "$failures" -eq 0 ]; then
    echo "check-layers: all $cases cases passed"
    exit 0
fi
echo "check-layers: $failures expectation(s) failed in $cases cases"
exit 1
