# Session Core Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the 17 session-core files of the iOS app into a local Swift package, `MaraudersAuth`, without changing what the app does.

**Architecture:** The package sits beside the app folder and is linked into the app target only; the unit test bundle reaches it through the app that hosts it. The package has two targets, a Domain half and a Data half, and owns four small seams (transport, base URL, log sink, UI-test flag) that the app fills from one bridge file. The layer checker learns to read the package's two source folders as more Domain and more Data.

**Tech Stack:** Swift 6.4 in language mode 6, SwiftPM tools 6.2, Xcode 27.2, Swift Testing, POSIX `sh` and the macOS `awk` for the layer checker.

**Spec:** `docs/superpowers/specs/2026-11-17-session-core-module-design.md`

## Global Constraints

- Work on branch `worktree-session-core-package` in its own worktree, created at execution time with superpowers:using-git-worktrees. Commit there after each task. Never push, never merge: both are the owner's yes.
- The main checkout has an uncommitted edit of `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` that belongs to the owner. Do not touch that file anywhere.
- Commit messages are one English sentence in the repository's style and end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Tests run on the iOS 27.2 simulator only (iPhone 17, id `902C645A-22D9-47F3-86B0-3E4623B6B2A9`), never on a phone. DerivedData goes to a scratch folder outside the repository.
- These stay byte for byte what they are: Keychain service `com.somsak.Marauders.auth`; accounts `apiAccessToken`, `apiRefreshToken`, `appleUserID`; accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; marker file `Application Support/Installation/session-initialized`.
- No file or type is renamed. Files move with `git mv`.
- No test is deleted or weakened. An existing test changes only by import lines unless a step says otherwise.
- Package: folder `Marauders-ios/Packages/MaraudersAuth`, tools version 6.2, language mode 6, platforms iOS 27.0 and macOS 26.0, one product `MaraudersAuth` made of the targets `MaraudersAuth` and `MaraudersAuthData`, each with `.defaultIsolation(MainActor.self)` and the upcoming features `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `MemberImportVisibility`.
- `MaraudersAuth` imports Foundation only. `MaraudersAuthData` imports Foundation, Security and `MaraudersAuth`. Neither names anything of the app.
- Log categories and texts do not change.
- `swift-format lint` prints nothing (line length 120, ordered imports).
- Nothing reads, prints or commits `backend/.dev.vars`.

## Commands

Paths in this plan are relative to the worktree root. Define these once per shell, from the worktree root; the steps
call them by name:

```bash
SCRATCH=<a folder outside the repository that this run may write to>
SIM=902C645A-22D9-47F3-86B0-3E4623B6B2A9
xcb() { xcodebuild "$@" -project Marauders-ios/Marauders.xcodeproj -scheme Marauders \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$SCRATCH/DerivedData-sim" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages"; }

UNIT()    { xcb test -only-testing:MaraudersTests 2>&1 | grep -E "Test run with|\*\* TEST"; }
SUITE()   { xcb test -only-testing:"MaraudersTests/$1" 2>&1 | grep -E "✘|error:|Test run with|\*\* TEST"; }
BUILD()   { xcb build 2>&1 | grep -E "error:|\*\* BUILD"; }
LINT()    { xcrun swift-format lint -r Marauders-ios/Marauders Marauders-ios/MaraudersTests \
              Marauders-ios/MaraudersUITests $(ls -d Marauders-ios/Packages 2>/dev/null); }
CHECKER_TESTS() { sh Marauders-ios/Scripts/tests/check-layers-tests.sh; }
STRICT()  { sh Marauders-ios/Scripts/check-layers.sh --strict; echo "exit=$?"; }
PACKAGE() { swift build --package-path Marauders-ios/Packages/MaraudersAuth --scratch-path "$SCRATCH/swiftpm"; }
```

They pass when: UNIT and SUITE print `Test run with N tests in M suites passed` and `** TEST SUCCEEDED **`; BUILD prints
`** BUILD SUCCEEDED **` and no `error:`; LINT prints nothing; CHECKER_TESTS prints `check-layers: all N cases passed`;
STRICT prints only `exit=0`; PACKAGE ends with `Build complete!`.

To see every compile error of a build in one run, add `-IDEBuildingContinueBuildingAfterErrors=YES`. If the simulator is
busy: `xcrun simctl boot $SIM; xcrun simctl bootstatus $SIM -b`.

## Review Focus

What the spec implies and a build could get wrong without any ordinary test noticing, most likely first. Each has its test in the task named.

1. A build installed over the one before it finds no session, because a Keychain name, the accessibility class or the marker path changed: the viewer is signed out. Pinned by `SessionStorageNamesTests` (Task 1), which must pass unchanged after Task 4.
2. The unit tests run against a second copy of the module, so they prove nothing about the app's own. Pinned by `theTestsSeeTheGuardTheAppSetAtLaunch` (Task 1).
3. A request of the auth client goes to another address once the module forms its own URLs. Pinned by the four whole-URL assertions added to `AuthAPIClientTests` (Task 1).
4. A line the module logs never reaches the Debug log, or arrives at another level. Pinned by `AuthLogBridgeTests` (Task 4).
5. A transport error of the app's HTTP client is no longer asked again once by the refresher. Pinned by the existing `TokenRefresherTests.aTransportFailureIsRepeatedOnce`, and proved to depend on the new conformance by the mutation step of Task 4.

## File Structure

| File | What it is |
|---|---|
| `Marauders-ios/Packages/MaraudersAuth/Package.swift` | new: the package manifest |
| `…/MaraudersAuth/Sources/MaraudersAuth/` | the 9 files of `Marauders/Domain/Auth/` and `SignInWithAppleUseCase.swift`, moved |
| `…/MaraudersAuth/Sources/MaraudersAuthData/` | the 5 files of `Marauders/Data/Auth/`, `AuthAPIClient.swift`, `DevAuthAPIClient.swift`, moved; new `AuthTransport.swift`, `AuthLog.swift`, `AuthRoute.swift` |
| `Marauders-ios/Marauders/Data/Auth/AuthModuleBridge.swift` | new: the app's side of the seams |
| `Marauders-ios/Scripts/layer-modules.txt` | new: which folders outside `Marauders/` belong to which layer |
| `Marauders-ios/MaraudersTests/SessionStorageNamesTests.swift`, `AuthLogBridgeTests.swift` | new tests |
| `docs/adr/009-session-core-package.md` | new ADR |

Modified: `project.pbxproj`, the three checker files, `.gitignore`, `App/MaraudersApp.swift`, `Data/API/APIConfiguration.swift`, import lines in 13 other app files and 20 test files, and the documents listed in Task 5.

---

### Task 1: Pin what the move must not change

**Files:**
- Modify: `Marauders-ios/Marauders/Data/Auth/InstallationSessionGuard.swift`
- Create: `Marauders-ios/MaraudersTests/SessionStorageNamesTests.swift`
- Modify: `Marauders-ios/MaraudersTests/AuthAPIClientTests.swift`

**Interfaces:**
- Produces: `InstallationSessionGuard.markerURL() throws -> URL` (static, internal), which Task 4 moves with the file.

- [ ] **Step 1: Create the worktree and record the baseline**

Create the worktree and branch from `main`. Run UNIT, CHECKER_TESTS, STRICT.
Expected: `Test run with 1221 tests in 114 suites passed`, `check-layers: all 22 cases passed`, `exit=0`. If a number differs, stop and report: the counts in this plan assume this base.

- [ ] **Step 2: Write the failing test**

`Marauders-ios/MaraudersTests/SessionStorageNamesTests.swift`:

```swift
import Foundation
import Security
import Testing

@testable import Marauders

/// What must survive any change to the session code: a build that looks for the session under other names signs every
/// viewer out when it is installed over the build before it.
@MainActor
struct SessionStorageNamesTests {
    private static let service = "com.somsak.Marauders.auth"

    /// The text properties a store holds, private ones too.
    private static func names(of store: Any) -> [String: String] {
        var found: [String: String] = [:]
        for child in Mirror(reflecting: store).children {
            if let label = child.label, let value = child.value as? String { found[label] = value }
        }
        return found
    }

    @Test func theKeychainItemsKeepTheirServiceAndAccounts() {
        #expect(Self.names(of: KeychainAPIAccessTokenStore()) == ["service": Self.service, "account": "apiAccessToken"])
        #expect(
            Self.names(of: KeychainAPIRefreshTokenStore()) == ["service": Self.service, "account": "apiRefreshToken"])
        #expect(Self.names(of: KeychainAuthSessionStore()) == ["service": Self.service, "account": "appleUserID"])
    }

    @Test func aSavedTokenStaysOnThisDeviceAndIsReadableAfterTheFirstUnlock() throws {
        let service = "test.names." + UUID().uuidString
        let store = KeychainAPIAccessTokenStore(service: service)
        defer { try? store.clearAccessToken() }
        try store.saveAccessToken(String(repeating: "a", count: 32))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiAccessToken",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let accessible = (item as? [String: Any])?[kSecAttrAccessible as String] as? String
        #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func theInstallMarkerKeepsItsPlace() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let expected = support.appendingPathComponent("Installation/session-initialized")
        #expect(try InstallationSessionGuard.markerURL().standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test func theTestsSeeTheGuardTheAppSetAtLaunch() {
        #expect(InstallationSessionGuard.isReady, "false: a second copy of the session code, or the launch check failed")
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: SUITE `SessionStorageNamesTests`
Expected: the build fails with `type 'InstallationSessionGuard' has no member 'markerURL'`.

- [ ] **Step 4: Add `static func markerURL() throws -> URL` to `InstallationSessionGuard`**

It returns what `bootstrap()` computes inline today (the Application Support folder, created if needed, plus `Installation/session-initialized`), and `bootstrap()` calls it. Nothing else in the file changes. This is the one edit to a file that later moves which the spec's list (access modifiers, imports, the four seams) does not name; it exists so that a test can pin the marker's place.

- [ ] **Step 5: Run it to see it pass**

Run: SUITE `SessionStorageNamesTests`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 6: Pin the four request URLs in full**

In `AuthAPIClientTests.swift` add this helper to the suite:

```swift
/// The address a route has under the Worker's configured origin.
private static func workerURL(_ route: String) -> String? {
    (try? APIConfiguration.apiBaseURL()).flatMap { URL(string: route, relativeTo: $0)?.absoluteString }
}
```

and, right after each of the four existing lines `#expect(captured?.url?.path().hasSuffix("/v1/auth/<x>") == true)` (`<x>` is `apple`, `refresh`, `signout`, `dev`), add:

```swift
#expect(captured?.url?.absoluteString == Self.workerURL("v1/auth/<x>"))
```

- [ ] **Step 7: Run the suite, then everything**

Run: `SUITE AuthAPIClientTests`, then UNIT, then LINT.
Expected: `14 tests in 1 suite passed`; `1225 tests in 115 suites passed`; LINT prints nothing.

- [ ] **Step 8: Commit**

```bash
git add Marauders-ios/Marauders/Data/Auth/InstallationSessionGuard.swift Marauders-ios/MaraudersTests/SessionStorageNamesTests.swift Marauders-ios/MaraudersTests/AuthAPIClientTests.swift
git commit -m "Pin the session's Keychain names, its install marker and the auth request URLs"
```

---

### Task 2: The layer checker reads module folders

**Files:**
- Modify: `Marauders-ios/Scripts/check-layers.sh`, `Marauders-ios/Scripts/check-layers.awk`
- Test: `Marauders-ios/Scripts/tests/check-layers-tests.sh`

**Interfaces:**
- Produces, for Tasks 3 and 4:
  - Option `--modules FILE`. Default: `layer-modules.txt` next to `check-layers.sh`. A file that does not exist means no module folders.
  - File format, one module folder per line: `<Layer>: <folder>  # comment`. `<folder>` is relative to the folder that holds `--root` (for the default root, `Marauders-ios/`). Blank lines and lines starting with `#` are skipped. The folder's last path component is the module's name.
  - Meaning: (1) a Swift file under a module folder is a file of that layer, and every rule of the layer applies to it; (2) a top-level type declared there belongs to that layer; (3) an `import` of a module's name is allowed exactly where a type of its layer may be named, and is otherwise the finding `<Layer> imports '<Module>'; <Layer> must not depend on <ModuleLayer>`, recorded as `import <Module>`; (4) every other import is judged as today, with today's messages.
  - An exception line for a file in a module folder uses the file's path from the folder that holds `--root`.
  - Errors, exit status 2: `error: module folder not found: <folder>` and `error: unknown layer in <file>: <name>`.

- [ ] **Step 1: Write the failing cases**

In `check-layers-tests.sh`: `begin` also sets `MODULES="$CASE_DIR/modules.txt"` and empties it; `run` also passes `--modules "$MODULES"` before `"$@"`. Add the two helpers and the seven cases below, before the `# --- result` block.

```sh
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
```

- [ ] **Step 2: Run them to see them fail**

Run: CHECKER_TESTS
Expected: exit 1, with `FAIL` lines in the old cases too: until Step 3 the checker rejects the option every case now
passes (`error: unknown option: --modules`).

- [ ] **Step 3: Implement `--modules` in `check-layers.sh` and `check-layers.awk`**

`check-layers.sh` parses the option, validates the file (the two errors above), adds the Swift files of each module folder to the list it hands to awk, and tells awk which folder is which layer. `check-layers.awk` gives such a file its layer in `layer_of`, uses the path from the folder that holds the root as the file's `rel`, and in `check_import` applies meaning (3) before the existing rules. Update the usage comment at the top of `check-layers.sh`: the option, the file format, and "Domain imports Foundation and the Domain module folders' modules". Keep to what the macOS awk has (no `gensub`, no `\b`, no `length(array)`).

- [ ] **Step 4: Run them to see them pass**

Run: CHECKER_TESTS, then STRICT.
Expected: `check-layers: all 29 cases passed`; `exit=0` (the real tree has no `layer-modules.txt` yet, so nothing changed for it).

- [ ] **Step 5: Commit**

```bash
git add Marauders-ios/Scripts
git commit -m "Let the layer checker read the source folders of local packages as part of a layer"
```

---

### Task 3: The package, with its Domain target

**Files:**
- Create: `Marauders-ios/Packages/MaraudersAuth/Package.swift`, `Marauders-ios/Scripts/layer-modules.txt`
- Move to `Marauders-ios/Packages/MaraudersAuth/Sources/MaraudersAuth/`: the 9 files of `Marauders-ios/Marauders/Domain/Auth/` and `Marauders-ios/Marauders/Domain/UseCases/SignInWithAppleUseCase.swift`
- Modify: `Marauders-ios/Marauders.xcodeproj/project.pbxproj`, `.gitignore`, and import lines (Steps 6 and 7)

**Interfaces:**
- Consumes: `--modules` and `layer-modules.txt` from Task 2.
- Produces: module `MaraudersAuth` with these 16 public types, unchanged in name and shape: `APIAccessTokenExpiry`, `APIAccessTokenFormat`, `APIAccessTokenStore`, `APIAccessTokenSubject`, `APIRefreshTokenFormat`, `APIRefreshTokenStore`, `AuthAPIClientProtocol`, `AuthAPIError`, `AuthSessionStore`, `AuthTokens` (with `public init(accessToken: String, refreshToken: String?)`), `AuthUserID`, `DevAuthExchanging`, `SignInAsDevUserUseCase` (Debug only, as today), `SignInWithAppleUseCase`, `TokenRefreshOutcome`, `TokenRefreshing`. `APIAccessTokenPayload` and `SignInError` stay internal.

- [ ] **Step 1: Write the manifest and move the files**

`Marauders-ios/Packages/MaraudersAuth/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

/// The app target's Swift settings (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, approachable concurrency, member import
/// visibility), so code moved here keeps its meaning.
let appSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "MaraudersAuth",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "MaraudersAuth", targets: ["MaraudersAuth"])
    ],
    targets: [
        .target(name: "MaraudersAuth", swiftSettings: appSettings)
    ],
    swiftLanguageModes: [.v6]
)
```

```bash
D=Marauders-ios/Packages/MaraudersAuth/Sources/MaraudersAuth
mkdir -p "$D"
git mv Marauders-ios/Marauders/Domain/Auth/*.swift "$D/"
git mv Marauders-ios/Marauders/Domain/UseCases/SignInWithAppleUseCase.swift "$D/"
printf '%s\n' 'Marauders-ios/Packages/*/.build/' 'Marauders-ios/Packages/*/.swiftpm/' >> .gitignore
```

- [ ] **Step 2: See the target stand alone**

Run: PACKAGE
Expected: `Build complete!`. The ten files name nothing outside themselves.

- [ ] **Step 3: Wire the package into the project and the lint phase**

```bash
python3 - Marauders-ios/Marauders.xcodeproj/project.pbxproj <<'EOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
BF, PD, PR = "A17E5E0000000000000000A1", "A17E5E0000000000000000A2", "A17E5E0000000000000000A3"
def once(old, new):
    global s
    assert s.count(old) == 1, (old, s.count(old))
    s = s.replace(old, new)
once("/* End PBXBuildFile section */",
     f"\t\t{BF} /* MaraudersAuth in Frameworks */ = {{isa = PBXBuildFile; productRef = {PD} /* MaraudersAuth */; }};\n/* End PBXBuildFile section */")
once("\t\t\t\t06BC2D3A3075A7FD0064F635 /* WhisperKit in Frameworks */,\n",
     f"\t\t\t\t06BC2D3A3075A7FD0064F635 /* WhisperKit in Frameworks */,\n\t\t\t\t{BF} /* MaraudersAuth in Frameworks */,\n")
once("\t\t\t\t06BC2D3B3075A7FD0064F635 /* WhisperKit */,\n\t\t\t);\n\t\t\tproductName = Marauders;",
     f"\t\t\t\t06BC2D3B3075A7FD0064F635 /* WhisperKit */,\n\t\t\t\t{PD} /* MaraudersAuth */,\n\t\t\t);\n\t\t\tproductName = Marauders;")
once('\t\t\t\t06BC2D3C3075A7FD0064F635 /* XCRemoteSwiftPackageReference "WhisperKit" */,\n\t\t\t);',
     f'\t\t\t\t06BC2D3C3075A7FD0064F635 /* XCRemoteSwiftPackageReference "WhisperKit" */,\n\t\t\t\t{PR} /* XCLocalSwiftPackageReference "Packages/MaraudersAuth" */,\n\t\t\t);')
once("/* Begin XCRemoteSwiftPackageReference section */",
     f'/* Begin XCLocalSwiftPackageReference section */\n\t\t{PR} /* XCLocalSwiftPackageReference "Packages/MaraudersAuth" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = Packages/MaraudersAuth;\n\t\t}};\n/* End XCLocalSwiftPackageReference section */\n\n/* Begin XCRemoteSwiftPackageReference section */')
once("/* End XCSwiftPackageProductDependency section */",
     f"\t\t{PD} /* MaraudersAuth */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = MaraudersAuth;\n\t\t}};\n/* End XCSwiftPackageProductDependency section */")
once(r'\"$SRCROOT/MaraudersUITests\" 2>&1', r'\"$SRCROOT/MaraudersUITests\" \"$SRCROOT/Packages\" 2>&1')
open(p, "w", encoding="utf-8").write(s)
EOF
plutil -lint Marauders-ios/Marauders.xcodeproj/project.pbxproj
```

Expected: `project.pbxproj: OK`. The test targets get no package entry.

- [ ] **Step 4: Tell the checker about the folder**

`Marauders-ios/Scripts/layer-modules.txt`:

```text
# Folders outside Marauders/ that belong to a layer: the source folders of local packages.
# One per line:   <Layer>: <folder, from Marauders-ios/>   # what it holds
Domain: Packages/MaraudersAuth/Sources/MaraudersAuth  # token rules, store protocols, the sign-in use cases
```

- [ ] **Step 5: Make the 16 types public**

Mark the types listed under Interfaces `public`, write `AuthTokens`' public initializer, and mark `public` the initializers of the two use cases and the members that the next two steps' builds ask for. Add nothing else and change no body.

- [ ] **Step 6: Import the module in the app**

Add `import MaraudersAuth` (in sorted position) to: `Composition/APITransportComposition.swift`, `Composition/AppDependencyContainer.swift`, `Composition/DebugSessionFault.swift`, `Composition/UITestRejectedSession.swift`, `Data/API/APIAuthorization.swift`, `Data/API/DubbedAudioCacheClient.swift`, `Data/API/TokenRefreshingHTTPClient.swift`, `Data/API/AuthAPIClient.swift`, `Data/API/DevAuthAPIClient.swift`, the five files of `Data/Auth/`, `Data/Services/FeedStartupCache.swift`, the three `Data/Upload/BackgroundClipUploader*.swift` files, `Domain/UseCases/RevokeRefreshTokenOnSignOutUseCase.swift`, `Presentation/Auth/AuthViewModel.swift` (all under `Marauders-ios/Marauders/`).

Run: BUILD. Member import visibility may name a few more files; add the import there too.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Import the module in the tests**

Add `@testable import MaraudersAuth` below `@testable import Marauders` in these files of `Marauders-ios/MaraudersTests/`: `APIAccessTokenExpiryTests`, `APITransportCompositionTests`, `AuthAPIClientTests`, `AuthViewModelTests`, `AuthViewModelUploadHooksTests`, `DebugSessionFaultTests`, `GuestFallbackTests`, `InstallationSessionGuardTests`, `RefreshTokenStoreTests`, `RevokeOnSignOutTests`, `SessionExpiryTests`, `SignInWithAppleUseCaseTests`, `SignOutLocationSharingTests`, `TokenRefresherTests`, `TokenRefreshingHTTPClientTests`, and in `Support/`: `MemoryRefreshTokenStore`, `ScriptedAuthAPI`, `ScriptedRefresher`, `SignOutSharingDoubles`, `UploaderKit`. Add it to any other test file the build names.

Run: UNIT
Expected: `Test run with 1225 tests in 115 suites passed`.

- [ ] **Step 8: Check the rules and the shape of the change**

Run: LINT, CHECKER_TESTS, STRICT, PACKAGE, then `git diff -M --cached --diff-filter=R --name-status HEAD | wc -l` after `git add -A Marauders-ios .gitignore`.
Expected: nothing; `all 29 cases passed`; `exit=0`; `Build complete!`; `10`.

- [ ] **Step 9: Commit**

```bash
git commit -m "Move the session's rules, store protocols and sign-in use cases into the MaraudersAuth package"
```

---

### Task 4: The Data target and the four seams

**Files:**
- Modify: `Marauders-ios/Packages/MaraudersAuth/Package.swift`, `Marauders-ios/Scripts/layer-modules.txt`
- Move to `Marauders-ios/Packages/MaraudersAuth/Sources/MaraudersAuthData/`: the 5 files of `Marauders-ios/Marauders/Data/Auth/`, `Marauders-ios/Marauders/Data/API/AuthAPIClient.swift`, `Marauders-ios/Marauders/Data/API/DevAuthAPIClient.swift`
- Create there: `AuthTransport.swift`, `AuthLog.swift`, `AuthRoute.swift`
- Create: `Marauders-ios/Marauders/Data/Auth/AuthModuleBridge.swift`
- Modify: `Marauders-ios/Marauders/App/MaraudersApp.swift`, `Marauders-ios/Marauders/Data/API/APIConfiguration.swift`, import lines (Steps 6 and 7)
- Test: `Marauders-ios/MaraudersTests/AuthLogBridgeTests.swift`

**Interfaces:**
- Consumes: module `MaraudersAuth` (Task 3); `InstallationSessionGuard.markerURL()` (Task 1).
- Produces, in `MaraudersAuthData`:

```swift
// AuthTransport.swift
public struct AuthTransportResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int)
    public var isSuccess: Bool          // 200...299
}
public protocol AuthTransport: Sendable {          // no isolation written: the module default, as HTTPClient has in the app
    func data(_ request: URLRequest) async throws -> AuthTransportResponse
}
nonisolated public protocol AuthTransportFailure: Error {}

// AuthLog.swift
public enum AuthLog {
    public enum Level: Sendable { case info, warning, error }
    public static var sink: (@MainActor (_ level: Level, _ category: String, _ message: String) -> Void)?
    static func info(_ category: String, _ message: String)       // each hands its level, category and message to sink
    static func warning(_ category: String, _ message: String)
    static func error(_ category: String, _ message: String)
}

// AuthRoute.swift (internal)
enum AuthRoute: String {
    case apple = "v1/auth/apple", refresh = "v1/auth/refresh", signOut = "v1/auth/signout", dev = "v1/auth/dev"
    func url(relativeTo base: URL) throws -> URL    // URL(string: rawValue, relativeTo: base), or throws AuthRouteError.invalidBaseURL
}
enum AuthRouteError: LocalizedError { case invalidBaseURL }   // errorDescription "API URL must be https:// with no path"

// moved types: public, with these initializers and members
AuthAPIClient.init(transport: any AuthTransport, baseURL: @escaping @MainActor () throws -> URL)
DevAuthAPIClient.init(transport: any AuthTransport, baseURL: @escaping @MainActor () throws -> URL)   // Debug only
InstallationSessionGuard.bootstrap(isUITesting: Bool)          // public; isReady is public private(set)
TokenRefresher.init(accessTokenStore:refreshTokenStore:authAPI:retryDelay:unavailableCooldown:now:)   // labels and defaults as today
KeychainAPIAccessTokenStore / KeychainAPIRefreshTokenStore / KeychainAuthSessionStore .init(service:account:)   // defaults as today
```

  `AuthAPIResponse`, `KeychainAuthSessionStoreError`, `markerURL()` and `resetIfNeeded(…)` stay internal.
- Produces, in the app (`AuthModuleBridge.swift`):

```swift
struct HTTPClientAuthTransport: AuthTransport { init(_ client: any HTTPClient) }
extension HTTPClientError: AuthTransportFailure {}
extension AuthAPIClient { init(session: URLSession = .shared) }
extension DevAuthAPIClient { init(client: any HTTPClient = URLSessionHTTPClient()) }    // inside #if DEBUG
extension AuthLog { static func forwardToAppLog() }    // .info to AppLog.info, .warning to AppLog.warning, .error to AppLog.error
```

  Both convenience initializers wrap their client in `HTTPClientAuthTransport` and pass `baseURL: { try APIConfiguration.apiBaseURL() }`; `init(session:)` wraps `URLSessionHTTPClient(session: session)`.

- [ ] **Step 1: Write the failing test**

`Marauders-ios/MaraudersTests/AuthLogBridgeTests.swift`:

```swift
import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuthData

/// A line the session module logs must reach the app's log with its level, category and text. The test sets no sink:
/// it passes only when the app pointed the module's log at `AppLog` when it launched.
@Suite(.serialized)
@MainActor
struct AuthLogBridgeTests {
    /// `AppLog` writes from a task of its own, so an entry shows up a moment after the call that logged it.
    private static func entry(_ message: String) async -> AppLogEntry? {
        for _ in 0..<200 {
            let found = AppLogStore.shared.entries.last { $0.category == "auth.bridge" && $0.message == message }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func aLineOfTheModuleReachesTheAppLogAtItsLevel() async {
        let mark = UUID().uuidString
        AuthLog.info("auth.bridge", "info \(mark)")
        AuthLog.warning("auth.bridge", "warning \(mark)")
        AuthLog.error("auth.bridge", "error \(mark)")

        #expect(await Self.entry("info \(mark)")?.level == .info)
        #expect(await Self.entry("warning \(mark)")?.level == .warning)
        #expect(await Self.entry("error \(mark)")?.level == .error)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: SUITE `AuthLogBridgeTests`
Expected: the build fails with `no such module 'MaraudersAuthData'`.

- [ ] **Step 3: Add the target, the seam files, and move the seven files**

In `Package.swift` the product becomes `targets: ["MaraudersAuth", "MaraudersAuthData"]` and the target list gains
`.target(name: "MaraudersAuthData", dependencies: ["MaraudersAuth"], swiftSettings: appSettings)`.

```bash
D=Marauders-ios/Packages/MaraudersAuth/Sources/MaraudersAuthData
mkdir -p "$D"
git mv Marauders-ios/Marauders/Data/Auth/*.swift "$D/"
git mv Marauders-ios/Marauders/Data/API/AuthAPIClient.swift Marauders-ios/Marauders/Data/API/DevAuthAPIClient.swift "$D/"
```

Create `AuthTransport.swift`, `AuthLog.swift` and `AuthRoute.swift` there as the Interfaces block gives them. Add the line `Data: Packages/MaraudersAuth/Sources/MaraudersAuthData  # Keychain stores, the refresher, the install guard, the auth clients` to `layer-modules.txt`.

- [ ] **Step 4: Put the seams into the moved files**

Only these lines change, besides `import MaraudersAuth` and `public`:

| File | Today | Becomes |
|---|---|---|
| `AuthAPIClient.swift` | stored `client: HTTPClient`, both initializers | `transport: any AuthTransport`, `baseURL`, the one initializer above |
| `AuthAPIClient.swift` | `try APIConfiguration.appleAuthURL()`, `.refreshAuthURL()`, `.signOutAuthURL()` | `try AuthRoute.apple.url(relativeTo: try baseURL())`, `.refresh`, `.signOut` |
| `AuthAPIClient.swift`, `DevAuthAPIClient.swift` | `client.data(request)` | `transport.data(request)` |
| `DevAuthAPIClient.swift` | stored `client`, its initializer, `try APIConfiguration.devAuthURL()` | as `AuthAPIClient`, with `AuthRoute.dev` |
| all four files that log | `AppLog.info` / `.warning` / `.error` (8 calls) | `AuthLog.info` / `.warning` / `.error`, same arguments, same `await` |
| `TokenRefresher.swift` | `error is URLError \|\| error is HTTPClientError` | `error is URLError \|\| error is any AuthTransportFailure` |
| `InstallationSessionGuard.swift` | `static func bootstrap()`, `guard !AppRuntimeConfiguration.isUITesting` | `public static func bootstrap(isUITesting: Bool)`, `guard !isUITesting` |

Run: PACKAGE
Expected: `Build complete!`. Both targets stand without the app.

- [ ] **Step 5: Write the app's side**

Create `AuthModuleBridge.swift` as the Interfaces block gives it. In `MaraudersApp.init()` replace the line `InstallationSessionGuard.bootstrap()` with:

```swift
// First: the session module logs through this, and the install check below may log.
AuthLog.forwardToAppLog()
InstallationSessionGuard.bootstrap(isUITesting: AppRuntimeConfiguration.isUITesting)
```

In `APIConfiguration.swift` delete `appleAuthURL()`, `refreshAuthURL()`, `signOutAuthURL()` and `devAuthURL()` with their comments.

- [ ] **Step 6: Import the Data target in the app**

Add `import MaraudersAuthData` to `App/MaraudersApp.swift`, `Composition/AppDependencyContainer.swift`, `Composition/DebugSessionFault.swift`, `Data/API/DubbedAudioCacheClient.swift`, `Data/Services/FeedStartupCache.swift` and the bridge file, and to any file the build names.

Run: BUILD
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Import it in the tests and run everything**

Add `@testable import MaraudersAuthData` to `APITransportCompositionTests`, `AuthAPIClientTests`, `InstallationSessionGuardTests`, `RefreshTokenStoreTests`, `SessionStorageNamesTests`, `TokenRefresherTests`, `TokenRefreshingHTTPClientTests`, and to any file the build names.

Run: UNIT
Expected: `Test run with 1226 tests in 116 suites passed`.

- [ ] **Step 8: Prove two tests guard the wiring**

Each change is made, observed and undone; `git diff --stat` must show the file as it was before it.

1. Remove the line `AuthLog.forwardToAppLog()` from `MaraudersApp.init()`. Run SUITE `AuthLogBridgeTests` and SUITE `TokenRefresherTests`. Expected: `aLineOfTheModuleReachesTheAppLogAtItsLevel` and `noTokenReachesTheAppLog` fail. Put the line back.
2. Remove `extension HTTPClientError: AuthTransportFailure {}` from the bridge. Run SUITE `TokenRefresherTests`. Expected: `aTransportFailureIsRepeatedOnce` fails for its two `HTTPClientError` arguments. Put it back.

Run: UNIT again. Expected: `1226 tests in 116 suites passed`.

- [ ] **Step 9: Check the rules and the shape of the change**

Run: LINT, CHECKER_TESTS, STRICT, then, after `git add -A Marauders-ios`:

```bash
git diff -M --cached --diff-filter=R --name-status HEAD | wc -l
grep -rho '"com.somsak.Marauders.auth"' Marauders-ios/Packages | wc -l
grep -rhoE '"(apiAccessToken|apiRefreshToken|appleUserID)"|kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly|Installation/session-initialized' Marauders-ios/Packages | sort | uniq -c
```

Expected: nothing; `all 29 cases passed`; `exit=0`; `7`; `6`; one of each account name, three of the accessibility class, one marker path.

- [ ] **Step 10: Commit**

```bash
git commit -m "Move the Keychain stores, the refresher and the auth clients into MaraudersAuthData behind four seams"
```

---

### Task 5: Documentation

**Files:**
- Create: `docs/adr/009-session-core-package.md`
- Modify: `docs/adr/README.md`, `docs/adr/004-single-app-target.md`, `docs/adr/007-token-refresh.md`, `ARCHITECTURE.md`, `README.md`

**Interfaces:**
- Consumes: the names and rules Tasks 2 to 4 produced.

- [ ] **Step 1: Write ADR-009**

In the form of ADR-004 (Status, Date 2026-11-17, Scope; Context; Decision; Alternatives considered; Consequences; References). It records, from the spec: why now (the owner's choice; clean build 21 s, rebuild 7 s, unit loop 27 s, so speed is not the reason); the package, its two targets and what each holds; the four seams and which outside name each replaced; the three cuts measured and the two decisions inside the chosen one; that `RevokeRefreshTokenOnSignOutUseCase` stays in the app and why; the consequences (23 public types, `Domain/` may import `MaraudersAuth`, the checker reads `layer-modules.txt`, one piece of module-wide state in `AuthLog.sink`, tests still hosted by the app); and what a second module would reuse.

- [ ] **Step 2: Update the documents that describe what moved**

- `docs/adr/README.md`: a row for 009, "The session core as a local Swift package".
- `docs/adr/004-single-app-target.md`: under Status, "Amended by [ADR-009](009-session-core-package.md): the session core is a local package; everything else is as decided here."
- `docs/adr/007-token-refresh.md`: the path of `TokenRefresher.swift`.
- `ARCHITECTURE.md`: the packaging sentence under "MVVM + Clean Architecture"; the layer table (Domain and Data rows name the package's targets); the dependency-rules table (Domain may import `Foundation` and `MaraudersAuth`; Presentation and Shared may not import `MaraudersAuthData`); the Enforcement paragraph (`layer-modules.txt`, what it makes the checker do); the module map (a `Packages/MaraudersAuth/` block, `Data/Auth/` now holding `AuthModuleBridge`); the Tests section (the checker's case count 29, the two new suites, and the counts printed by `grep -rho '@Test' Marauders-ios/MaraudersTests | wc -l` and `grep -rl '@Test' Marauders-ios/MaraudersTests | wc -l`).
- `README.md`: the repository layout gains `Packages/`.

- [ ] **Step 3: Check that no document points at a path that is gone**

Run: `grep -rn "Domain/Auth\|Data/Auth/Keychain\|Data/Auth/TokenRefresher\|Data/Auth/InstallationSessionGuard\|Data/API/AuthAPIClient\|Data/API/DevAuthAPIClient" ARCHITECTURE.md README.md docs/adr Marauders-ios/Scripts`
Expected: only lines of `docs/adr/009-session-core-package.md` that say where a file came from.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md README.md docs/adr
git commit -m "Record the session core package in ADR 009 and the architecture documents"
```

---

### Task 6: Verify the whole branch

**Files:** none.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: The package stands alone, and the move is a move**

Run: PACKAGE, then `git diff -M --diff-filter=R --name-status main..HEAD | wc -l`
Expected: `Build complete!`; `17`.

- [ ] **Step 2: Rules**

Run: LINT, CHECKER_TESTS, STRICT.
Expected: nothing; `all 29 cases passed`; `exit=0`.

- [ ] **Step 3: The checker sees a break in the package**

In a copy (`mkdir -p "$SCRATCH/probe" && git archive HEAD Marauders-ios | tar -x -C "$SCRATCH/probe"`), add `import SwiftUI` to one file of each package folder, and the line `let signIn: SignInWithAppleUseCase? = nil` inside the struct of `Marauders/Presentation/Auth/SignInRequiredView.swift`. The copy is only read by the checker, never compiled. Run `sh "$SCRATCH/probe/Marauders-ios/Scripts/check-layers.sh"`.
Expected: exactly three findings: `Domain imports 'SwiftUI'`, `Data imports 'SwiftUI'`, `View names Domain use case or repository 'SignInWithAppleUseCase'`.

- [ ] **Step 4: Unit and UI tests**

Run: UNIT; then, in the background (it takes 16 to 34 minutes), `xcb test -only-testing:MaraudersUITests`.
Expected: `1226 tests in 116 suites passed`; the UI target ends with 51 of 52 passing, the one failure being `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` (a system Translate sheet on the simulator, red on `main` too). Run any other failing UI test alone before reading it as real.

- [ ] **Step 5: Release**

```bash
xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme Marauders -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/DerivedData-release" \
  -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" -archivePath "$SCRATCH/check.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | grep -E "error:|\*\* ARCHIVE"
ls "$SCRATCH/check.xcarchive/Products/Applications/Marauders.app/Frameworks"
```

Expected: `** ARCHIVE SUCCEEDED **`; `Lottie.framework` and nothing else.

- [ ] **Step 6: Report, and stop**

Report each result above with its output. Two things are not done here and are the owner's to order: the check that a session survives the update (spec, Verification 9: it signs a test user in on the live Worker), and merging the branch.
