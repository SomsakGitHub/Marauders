# Force Update from Firebase Remote Config: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The force-update gate takes its minimum build and its Update link from Firebase Remote Config instead of a Worker route, and a build with no usable plist runs exactly as it does today.

**Architecture:** A new Data repository, `FirebaseAppConfigRepository`, replaces the Worker one: it parses two texts it gets from a `RemoteConfigSource` and keeps the gate's answer in the same UserDefaults entry. `FirebaseRemoteConfigSource` is the only file that imports Firebase; it starts the SDK at the first ask behind a pure plist check, so a bad plist means "gate open", never a crash. Domain, Presentation, the Update screen and the UITEST scenarios do not change. A lane check and a script test carry the git-ignored plist from Jenkins into the shipped build.

**Tech Stack:** Swift 6 (MainActor default isolation) and Swift Testing; firebase-ios-sdk 13.2.0; POSIX sh with `plutil`; fastlane (Ruby); Node `node --test`.

**Spec:** `docs/superpowers/specs/2026-11-21-firebase-remote-config-design.md` (approved by the owner 2026-11-21). The gate it keeps is described in `docs/adr/012-force-update.md`, which Task 7 rewrote for Firebase.

## Global Constraints

- **SDK:** `firebase-ios-sdk`, "up to next major" from `13.2.0`; products `FirebaseCore` and `FirebaseRemoteConfig` only (no Analytics). Settings: `minimumFetchInterval = 3600`, `fetchTimeout = 10`.
- **Parameters:** `minimum_build` (Number) and `update_url` (String), read as text. The number is parsed with `BuildNumber.parse`; anything else, an absent parameter included, is 0. No in-app defaults.
- **Kept answer and logs:** UserDefaults key `update.appConfig.v1` (JSON of `AppConfig`); logs under `update`: `config refreshed: minimumBuild=<n>`. A plist value is never logged, and the repo is public: fixtures and docs hold only obviously fake values.
- **Plist:** `Marauders-ios/Marauders/GoogleService-Info.plist`, git-ignored; Jenkins file credential `marauders-firebase-plist` bound to `FIREBASE_PLIST_PATH`; `BUNDLE_ID` must be `com.somsak.Marauders`; `GOOGLE_APP_ID` must match `^1:[0-9]+:ios:[0-9a-fA-F]+$`.
- **Never:** a crash on a missing or malformed plist; Google contacted before the pass check, in a UI test or on the first frame's path; a change to a scheme or to `check-release-config.sh`; a new layer exception (the 9 stay); a Firebase import outside `FirebaseRemoteConfigSource.swift`.
- **Unchanged and still green:** `UpdateDecision`, `CheckUpdateRequirementUseCase`, `UpdateGateViewModel`, `UpdateRequiredView`, `MaraudersApp` (comments aside), the three Update strings and their tests.
- **App conventions:** test doubles are `final class … @unchecked Sendable`, never `actor`; pure non-isolated types are `nonisolated`; swift-format (4 spaces, 120 columns); no new user-visible text.
- **Owner's rules:** every test runs on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9`, never the phone. **No step commits, pushes, deploys or starts a TestFlight build**: the owner decides the commit grouping at the end. Never stage `docs/superpowers/plans/2026-11-21-client-key.md` or `docs/superpowers/specs/2026-11-21-client-key-design.md`.

**Test commands.** `S` is this session's scratchpad (it does not survive a reboot; the ledger lives in `.superpowers/sdd/`). One suite:

```
xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Staging" -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' -derivedDataPath $S/DerivedData-sim -clonedSourcePackagesDirPath $S/SourcePackages -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
```

Write one `-only-testing:` argument per suite out in full, and read the `Test run with N tests` line before believing a green run: a filter that matches nothing also ends `TEST SUCCEEDED`. The whole unit target is `-only-testing:MaraudersTests`; the baseline before this plan is 1456 tests in 146 suites.

## Review Focus

1. A plist that is present but cannot start the SDK (garbage, `GOOGLE_APP_ID` missing or of another shape) leaves the app running with the gate open, never a crash. Pinned by `FirebasePlistCheckTests` (Task 3) and the plist-less and fixture-plist runs of Task 8.
2. A console typo in `minimum_build` ("12o", "1.5", "-3", "+5", too large, empty, absent) reads as 0: it never blocks by accident and never crashes. Pinned by the parse table (Task 2).
3. A fetch that fails, times out or is cancelled while "required" is kept leaves "required" kept and rewrites nothing. Pinned by `aFailedRefreshReturnsNilAndKeepsTheEarlierAnswer` and `aCancelledRefreshKeepsNothing` (Task 2).
4. Publishing 0, or deleting the parameter, lifts the screen without a relaunch. Pinned by `aClearedMinimumReplacesAKeptMinimum`, `anAbsentParameterReadsAsNoGate` (Task 2) and `aRefreshAsksTheSourceOnceAndAClearedMinimumLiftsTheScreen` (Task 5).
5. A shipped build with no plist, another app's plist or an unusable `GOOGLE_APP_ID` stops the TestFlight lane before it builds. Pinned by `check-firebase-plist-tests.sh` and the wiring tests (Task 6).

## File Structure

| File (under `Marauders-ios/` unless noted) | Change | Responsibility |
|---|---|---|
| `Marauders/Data/Repositories/RemoteConfigSource.swift` | create | `RemoteConfigValues` (the two texts) and `RemoteConfigSource` (the seam over the SDK) |
| `Marauders/Data/Repositories/FirebaseAppConfigRepository.swift` | create | parses the texts, keeps the answer, logs; replaces `DefaultAppConfigRepository` |
| `Marauders/Data/Repositories/FirebasePlistCheck.swift` | create | the pure start-up guard |
| `Marauders/Data/Repositories/FirebaseRemoteConfigSource.swift` | create | the only Firebase importer: start the SDK once, fetch, read the two texts |
| `Marauders/Composition/UpdateGateComposition.swift` | modify | takes `source:` in place of `client:` |
| `Marauders/Data/API/AppConfigAPIClient.swift`, `Marauders/Data/Repositories/DefaultAppConfigRepository.swift`, `MaraudersTests/AppConfigRepositoryTests.swift` | delete | the Worker client, repository and tests |
| `Marauders/Data/API/APIConfiguration.swift` | revert to HEAD | drops `appConfigURL()` |
| `Marauders.xcodeproj/project.pbxproj`, `…/swiftpm/Package.resolved` | modify | the package |
| `MaraudersTests/FirebaseAppConfigRepositoryTests.swift`, `FirebasePlistCheckTests.swift`, `Support/FakeRemoteConfigSource.swift` | create | |
| `MaraudersTests/UpdateGateCompositionTests.swift` | modify | `source:` instead of `client:` |
| `Scripts/check-firebase-plist.sh`, `Scripts/tests/check-firebase-plist-tests.sh` | create | the lane's plist check and its tests |
| `fastlane/Fastfile`, `../Jenkinsfile`, `../.gitignore` | modify | place and check the plist; bind the credential; keep it out of git |
| `../backend/test/scripts/firebasePlistInjection.test.mjs` | create | pins the SDK, the confinement and every hand-off |
| `../backend/` (route, vars, `test:config`, parity entries) | remove | the Worker work |
| `../docs/adr/012-force-update.md`, `../docs/adr/README.md`, `../ARCHITECTURE.md`, `../README.md`, `../deployment/README.md`, `../docs/ci-cd.md` | modify | rewritten around Firebase |

---

### Task 1: Keep the first-party route, then take it out of `backend/`

**Files:** create `.superpowers/sdd/kept-worker-config-route/` (git-ignored); delete `backend/src/appConfig.ts`, `backend/scripts/test-config.mjs`, `backend/test/config.test.ts`; revert to HEAD `backend/package.json`, `backend/src/index.ts`, `backend/wrangler.toml`, `backend/test/scripts/parity.test.mjs`; edit only a message in `backend/test/scripts/clientKeyInjection.test.mjs`.

**Interfaces:** Produces the kept folder that Tasks 5 and 7 check their deletions against, and a backend with no `/v1/config`.

- [ ] **Step 0: Snapshot the BASE.** Nothing of the first-party work is committed, so the final review cannot diff against `HEAD`. Before the first edit, with `WORK=.superpowers/sdd/2026-11-21-firebase-remote-config`: `git rev-parse HEAD > $WORK/base.sha`, and `rsync -aR` every path that `git status --porcelain` lists (directories included) into `$WORK/base/`. The review diffs the working tree against that folder, so it sees only this plan's changes.
- [ ] **Step 1: Save the first-party route.** Into the kept folder: `git diff -- backend/` as `tracked-backend.patch`; `git diff -- Marauders-ios/Marauders/Data/API/APIConfiguration.swift` as `tracked-app.patch`; `git diff -- README.md ARCHITECTURE.md deployment/README.md docs/ci-cd.md docs/adr/README.md` as `tracked-docs.patch`; copies (`rsync -aR`, relative paths kept) of the three untracked backend files, of `Marauders-ios/Marauders/Data/API/AppConfigAPIClient.swift`, `…/Data/Repositories/DefaultAppConfigRepository.swift`, `…/Composition/UpdateGateComposition.swift`, `Marauders-ios/MaraudersTests/AppConfigRepositoryTests.swift`, `…/UpdateGateCompositionTests.swift`, `docs/adr/012-force-update.md`, `docs/superpowers/specs/2026-11-21-force-update-design.md` and `docs/superpowers/plans/2026-11-21-force-update.md`; and a `README.txt` saying what each is and how to restore (apply the patches, copy the files back).
- [ ] **Step 2: Prove the copy.** `git apply --check -R` on each patch, and `cmp` each copy against its source. Expected: no output, exit 0 for every command. Only then go on.
- [ ] **Step 3: Remove the route.** `git checkout -- <the four tracked files>` and `rm` the three untracked ones. In `clientKeyInjection.test.mjs` change only the test title "…never asks the Worker for the minimum: the refresh follows the pass check" to name Firebase; its assertions stay.
- [ ] **Step 4: Verify.** `cd backend && npm test`: Expected: every runner passes and none is `test:config`. `git diff --stat -- backend/`: Expected: only `backend/test/scripts/clientKeyInjection.test.mjs`. `git grep -n "v1/config\|MINIMUM_BUILD\|UPDATE_URL\|appConfig\.ts\|appConfigBody\|test:config" -- backend`: Expected: no output (a bare `appConfig` also matches the unrelated `appConfiguration` of `iosEnvironments.test.mjs`).

### Task 2: `FirebaseAppConfigRepository` over a `RemoteConfigSource`

**Files:** create `Marauders/Data/Repositories/RemoteConfigSource.swift`, `Marauders/Data/Repositories/FirebaseAppConfigRepository.swift`, `MaraudersTests/Support/FakeRemoteConfigSource.swift`, `MaraudersTests/FirebaseAppConfigRepositoryTests.swift`.

**Interfaces:**
- Consumes: `AppConfig`, `AppConfigRepository` (`cached() -> AppConfig?`, `refresh() async -> AppConfig?`), `BuildNumber.parse(_:) -> Int?`, `AppLog`, test helper `ThrowawayDefaults` (`.defaults`).
- Produces:
  ```swift
  struct RemoteConfigValues: Equatable, Sendable { let minimumBuild: String; let updateURL: String }  // "" when a parameter is absent
  protocol RemoteConfigSource: Sendable { func fetch() async -> RemoteConfigValues? }               // nil on any failure
  struct FirebaseAppConfigRepository: AppConfigRepository {
      static let defaultsKey = "update.appConfig.v1"
      init(source: any RemoteConfigSource, defaults: UserDefaults = .standard)
  }
  final class FakeRemoteConfigSource: RemoteConfigSource, @unchecked Sendable {
      init(_ results: [RemoteConfigValues?], cancelsWhileFetching: Bool = false)  // call n answers results[n], the last one after that
      private(set) var fetchCount: Int
  }
  ```
  `RemoteConfigSource` follows its sibling protocols (default MainActor isolation); `FakeRemoteConfigSource` is modelled on `FakeAppConfigRepository`, and with `cancelsWhileFetching` its `fetch()` cancels its own task (`withUnsafeCurrentTask { $0?.cancel() }`) before answering.

- [ ] **Step 1: Write the failing tests** (`@MainActor struct FirebaseAppConfigRepositoryTests`; each test builds a `ThrowawayDefaults` and a repository over `FakeRemoteConfigSource`; `link` is `https://apps.apple.com/app/id1`):

  | Test | Assertion |
  |---|---|
  | `nothingIsKeptBeforeTheFirstRefresh` | `cached() == nil` |
  | `aGoodAnswerIsReturnedAndKeptAcrossALaunch` | `refresh()` returns `AppConfig(minimumBuild: 12, updateURL: link)` for `("12", link)`; a second repository on the same defaults, over a source that would answer nil, `cached()` equals it and its `fetchCount == 0` |
  | `theMinimumIsParsedLikeTheBuildNumber` (the source answers `(text, link)`; compare `refresh()?.minimumBuild`) | `"12"`→12, `" 7\n"`→7, `"0"`→0, `""`→0, `"12o"`→0, `"1.5"`→0, `"-3"`→0, `"+5"`→0, `"99999999999999999999"`→0 |
  | `theLinkIsTrimmedAndAnEmptyOneIsNone` (the source answers `("12", text)`; compare `refresh()?.updateURL`) | `""`→nil, `"   "`→nil, `" https://apps.apple.com/app/id1\n"`→`link` |
  | `anAbsentParameterReadsAsNoGate` | `("", "")` returns `AppConfig(minimumBuild: 0, updateURL: nil)` and keeps it |
  | `aClearedMinimumReplacesAKeptMinimum` | after `("99", link)` then `("0", "")`, `cached()` is `AppConfig(minimumBuild: 0, updateURL: nil)` |
  | `aFailedRefreshReturnsNilAndKeepsTheEarlierAnswer` | after a good answer, a nil one returns nil and `cached()` still holds the good one |
  | `aFirstRefreshThatFailsKeepsNothing` | nil answer: `refresh() == nil` and `defaults.object(forKey: defaultsKey) == nil` |
  | `aCancelledRefreshKeepsNothing` | `await Task { await repository.refresh() }.value` over a source with `cancelsWhileFetching: true` and a good answer is nil and writes no entry |
  | `anEntryThatNoLongerDecodesIsRemoved` | garbage `Data`, and a `String`, under the key: `cached() == nil` and the key is gone afterwards |

- [ ] **Step 2: Run to verify it fails** (suite `FirebaseAppConfigRepositoryTests`). Expected: the build fails with `cannot find 'FirebaseAppConfigRepository' in scope`.
- [ ] **Step 3: Implement** the three signatures above. `cached()` is the old `DefaultAppConfigRepository.cached()` moved over (decode, else remove the entry and log `kept config unreadable, removed`). `refresh()`: `guard let values = await source.fetch(), !Task.isCancelled` else log `config refresh failed` at warning and return nil; minimum `BuildNumber.parse(values.minimumBuild) ?? 0`; link trimmed, empty or unparsable → nil; keep the entry only now; log `config refreshed: minimumBuild=<n>` at info.
- [ ] **Step 4: Run to verify it passes** (same suite). Expected: `Test run with N tests in 1 suite passed`, N non-zero, 0 failures.

### Task 3: `FirebasePlistCheck`, the start-up guard

**Files:** create `Marauders/Data/Repositories/FirebasePlistCheck.swift`, `MaraudersTests/FirebasePlistCheckTests.swift`.

**Interfaces:** Produces (consumed by Task 4):
```swift
nonisolated enum FirebasePlistCheck {
    static func plist(atPath path: String?) -> [String: Any]?   // nil: no path, unreadable file, or a root that is not a dictionary
    static func problem(in plist: [String: Any]?) -> String?     // nil: the SDK can start from it; else the reason, never a plist value
}
```

- [ ] **Step 1: Write the failing tests** (`struct FirebasePlistCheckTests`; the fake app id in every fixture is `1:000000000000:ios:0000000000000000`, written to a temporary folder with `PropertyListSerialization`):
  - `aPlistWithAnIosAppIdIsUsable`: `problem(in: ["GOOGLE_APP_ID": goodID]) == nil`.
  - `noPlistIsNotUsable`: `problem(in: nil) != nil`.
  - `badAppIdsAreNotUsable` (arguments): the key absent, `""`, `1:000000000000:android:abc`, `1:000000000000:ios:`, `1:000000000000:ios:xyz`, `1:abc:ios:abc`, `2:000000000000:ios:abc`, `1:000000000000:ios:abc:extra`, and the good id with a leading space and with a trailing space: each `problem(in:) != nil`.
  - `aNonStringAppIdIsNotUsable`: `["GOOGLE_APP_ID": 5]`.
  - `thePlistIsReadFromAFile`: a valid file gives a dictionary holding the id; a missing path, `nil`, a file of garbage bytes and a file whose root is an array each give `nil`.
  - `theReasonNeverHoldsThePlistsValues`: for `["GOOGLE_APP_ID": "1:123456789012:android:abc"]`, the reason does not contain `123456789012`.
- [ ] **Step 2: Run to verify it fails.** Expected: `cannot find 'FirebasePlistCheck' in scope`.
- [ ] **Step 3: Implement** the two functions. The shape is exactly the regex of Global Constraints, applied to a `String` value only; reasons are two fixed texts (no usable plist; `GOOGLE_APP_ID` missing or malformed).
- [ ] **Step 4: Run to verify it passes.** Expected: the suite passes with 0 failures.

### Task 4: The package and `FirebaseRemoteConfigSource`

**Files:** modify `Marauders.xcodeproj/project.pbxproj`, `Marauders.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; create `Marauders/Data/Repositories/FirebaseRemoteConfigSource.swift`, `backend/test/scripts/firebasePlistInjection.test.mjs`.

**Interfaces:**
- Consumes: `RemoteConfigSource`, `RemoteConfigValues` (Task 2), `FirebasePlistCheck` (Task 3), `AppLog`.
- Produces: `struct FirebaseRemoteConfigSource: RemoteConfigSource` with `init()` that starts nothing, and `static let minimumBuildKey = "minimum_build"`, `static let updateURLKey = "update_url"`.

No unit test can start the SDK (it needs a plist and a network): its guard is Task 3's, its confinement and settings are pinned below, and its behaviour is proved in Tasks 8 and 9.

- [ ] **Step 1: Write the failing script tests** in `firebasePlistInjection.test.mjs` (style of `clientKeyInjection.test.mjs`: `node:test`, `BACKEND_DIR` from `../../scripts/lib/targets.mjs`, text files only, so it runs on the Ubuntu CI):
  - `onlyTheSourceFileImportsFirebase`: of all `*.swift` under `Marauders-ios/Marauders/`, exactly `Data/Repositories/FirebaseRemoteConfigSource.swift` matches `^\s*import Firebase`; it holds `FirebaseApp.configure(options:`, `@concurrent`, `minimumFetchInterval = 3600`, `fetchTimeout = 10` and the two keys `minimum_build` and `update_url`.
  - `theSdkIsAddedForTheTwoProductsOnly`: `project.pbxproj` has an `XCRemoteSwiftPackageReference` for `https://github.com/firebase/firebase-ios-sdk` with `kind = upToNextMajorVersion;` and `minimumVersion = 13.2.0;`, and the `productName = Firebase…;` values are exactly `FirebaseCore` and `FirebaseRemoteConfig`.
- [ ] **Step 2: Run** `cd backend && node --test test/scripts/firebasePlistInjection.test.mjs`. Expected: both FAIL (no file imports Firebase; no package reference).
- [ ] **Step 3: Add the package.** In `project.pbxproj`, copy every place that names Lottie (a `PBXBuildFile` and a Frameworks-phase entry per product, the target's `packageProductDependencies`, the project's `packageReferences`, one `XCRemoteSwiftPackageReference`, one `XCSwiftPackageProductDependency` per product) for `firebase-ios-sdk`, with the ids `FB0000000000000000000001` to `FB0000000000000000000005` (unused). Then `xcodebuild -resolvePackageDependencies -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Staging" -clonedSourcePackagesDirPath $S/SourcePackages`. Expected: `firebase-ios-sdk 13.2.0` and its dependencies are resolved; `git diff --stat` shows only `project.pbxproj` and `Package.resolved` changed there, `Package.resolved` gains pins, and no existing pin changes version (a changed pin is a finding: stop and ledger a ruling).
- [ ] **Step 4: Implement `FirebaseRemoteConfigSource`.** `fetch()` is `@concurrent`, so neither the plist read, the SDK start nor the fetch runs on the main actor (if the compiler refuses that witness, make the protocol requirement `nonisolated` and ledger a ruling). It starts the SDK only when `FirebaseApp.app() == nil`: read `Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")` through `FirebasePlistCheck.plist(atPath:)`, stop on `problem(in:)` or on `FirebaseOptions(contentsOfFile:) == nil` with `AppLog.warning("update", "firebase not started: <reason>; the gate stays open")` and answer nil, else `FirebaseApp.configure(options:)`. Then `RemoteConfig.remoteConfig()` with the two settings of Global Constraints, `try await ensureInitialized()`, `try await fetchAndActivate()`; `.successFetchedFromRemote` and `.successUsingPreFetchedData` (the SDK's own hour-long cache) both count as success, `.error` or a throw answers nil after `AppLog.warning("update", "firebase fetch failed: <NSError domain> <code>")`. On success return `RemoteConfigValues` from `configValue(forKey:).stringValue` of the two keys. Never log a plist value or an error's text.
- [ ] **Step 5: Verify.** Build the Staging scheme for the simulator in the background (the first build compiles the SDK, several minutes). Expected: `** BUILD SUCCEEDED **` and no warning from a file of ours. `node --test test/scripts/firebasePlistInjection.test.mjs`: Expected: both pass. `sh Marauders-ios/Scripts/check-layers.sh --strict`: Expected: exit 0, the 9 exceptions unchanged.

### Task 5: Switch the composition and delete the Worker client

**Files:** modify `Marauders/Composition/UpdateGateComposition.swift`, `MaraudersTests/UpdateGateCompositionTests.swift`; delete `AppConfigAPIClient.swift`, `DefaultAppConfigRepository.swift`, `AppConfigRepositoryTests.swift`; revert `Marauders/Data/API/APIConfiguration.swift`; reword comments.

**Interfaces:**
- Consumes: `FirebaseAppConfigRepository`, `FirebaseRemoteConfigSource`, `RemoteConfigSource`.
- Produces: `static func makeViewModel(defaults: UserDefaults = .standard, source: (any RemoteConfigSource)? = nil, currentBuild: Int? = BuildNumber.current, isDebugBuild: Bool = BuildNumber.isDebugBuild) -> UpdateGateViewModel`. The `FirebaseRemoteConfigSource()` is built only in the non-UITEST branch; UITEST still picks `UITestAppConfigRepository`.

- [ ] **Step 1: Port the three tests of `UpdateGateCompositionTests` one for one** to `source:` and `FakeRemoteConfigSource`, and to `FirebaseAppConfigRepository.defaultsKey`: `theKeptAnswerStopsABuildBelowItAtOnceWithNoRequest` (assert `source.fetchCount == 0`), `theRealBuildOfADeveloperIsNeverStopped`, and `aRefreshAsksTheSourceOnceAndAClearedMinimumLiftsTheScreen` (a source answering `("0", "")` after `refreshIfDue()`: `decision == .allowed`, `fetchCount == 1`). Reword the suite's doc comment.
- [ ] **Step 2: Run to verify it fails** (suite `UpdateGateCompositionTests`). Expected: the build fails, `extra argument 'source' in call`.
- [ ] **Step 3: Implement** the signature above. Then delete the three files and `git checkout -- Marauders/Data/API/APIConfiguration.swift`. Reword every comment that says the Worker serves the gate's numbers: `git grep -n "Worker" --` over `AppConfig.swift`, `UpdateDecision.swift`, `UpdateRequiredView.swift`, `CheckUpdateRequirementUseCase.swift`, `AppConfigRepository.swift`, `MaraudersApp.swift`, `UpdateGateViewModel.swift`, `UITestUpdateScenario.swift`, `BuildNumber.swift`, `UITestAppConfigRepository.swift`, `UpdateGateComposition.swift` and `CheckUpdateRequirementUseCaseTests.swift`; comments only, no code.
- [ ] **Step 4: Verify.** The suite: Expected: passes. The leftovers: `git grep -n "DefaultAppConfigRepository\|AppConfigAPIClient\|AppConfigAPIError\|appConfigURL" -- Marauders-ios` and the `Worker` grep above: Expected: no output. The whole unit target: Expected: 0 failures; the count is about 1456 − 12 (the `@Test` functions of the deleted file) + the new ones of Tasks 2 and 3: ledger the exact N. Then `sh Marauders-ios/Scripts/check-layers.sh --strict`, `xcrun swift-format lint -r Marauders-ios/Marauders Marauders-ios/MaraudersTests Marauders-ios/MaraudersUITests Marauders-ios/Packages` and `python3 Marauders-ios/Scripts/find-plain-strings.py`: Expected: all clean.

### Task 6: The plist hand-off (script, lane, Jenkins, gitignore)

**Files:** create `Marauders-ios/Scripts/check-firebase-plist.sh`, `Marauders-ios/Scripts/tests/check-firebase-plist-tests.sh`; modify `backend/test/scripts/firebasePlistInjection.test.mjs`, `Marauders-ios/fastlane/Fastfile`, `Jenkinsfile`, `.gitignore`.

**Interfaces:**
- Produces: `sh Scripts/check-firebase-plist.sh --plist <file> --bundle-id <id>`. Exit 0 and `firebase plist ok: <id>` only when the file is a plist, its `GOOGLE_APP_ID` has the shape of Global Constraints and its `BUNDLE_ID` equals `<id>`. Every failure prints one or more lines starting `error: ` and exits 1. It fails closed, reads and prints only, reads values with `plutil -extract <key> raw -o - <file>`, and never prints a plist value. Style: `check-release-config.sh`.
- Fastfile: `def place_firebase_plist` copies `ENV["FIREBASE_PLIST_PATH"]`, when set, over `File.join(PROJECT_ROOT, "Marauders", "GoogleService-Info.plist")`. `lane :build` calls it before `gym`. `lane :beta` calls it, then runs the script on that destination with `--bundle-id APP_IDENTIFIER` (absolute paths, `Shellwords.escape`), then `build`. A plain `build` or Xcode Run with no plist is untouched.

- [ ] **Step 1: Write the failing tests.** In `firebasePlistInjection.test.mjs`: `thePlistIsKeptOutOfGit` (`.gitignore` has the line `Marauders-ios/Marauders/GoogleService-Info.plist`); `theBuildLaneCopiesThePlistWhenJenkinsGivesIt` (the Fastfile reads `FIREBASE_PLIST_PATH` and names `GoogleService-Info.plist`, and `lane :build` calls the helper before `gym(`); `theBetaLaneChecksThePlistBeforeItBuilds` (inside `lane :beta`, `check-firebase-plist.sh` and `APP_IDENTIFIER` come before `build`); `jenkinsBindsThePlistWhereTheAppIsBuilt` (the Deploy stage's `withCredentials` holds `file(credentialsId: 'marauders-firebase-plist', variable: 'FIREBASE_PLIST_PATH')`, and nothing before that stage names the credential). In `check-firebase-plist-tests.sh` (copy the harness of `check-release-config-tests.sh`: `begin`, `run`, `expect_status`, `expect_text`, `expect_failure`; fixtures hold only `GOOGLE_APP_ID`, `BUNDLE_ID` and a marker `API_KEY` of `FIXTURE-NOT-A-KEY`), these cases: passes with a good plist; fails when the file is missing; fails when the file is not a plist; fails when `GOOGLE_APP_ID` is missing; fails for each wrong shape (android, empty hash, non-hex, version 2, an extra part, empty); fails when `BUNDLE_ID` is another app's; fails when `BUNDLE_ID` is missing; fails without `--plist`, without `--bundle-id` and with an unknown option; reports a wrong bundle and a wrong app id together as two `error:` lines; every failing line starts with `error: `; no output ever holds the marker or the fixture's project number.
- [ ] **Step 2: Run both to verify they fail.** `sh Marauders-ios/Scripts/tests/check-firebase-plist-tests.sh`: Expected: every case fails (the script is not there), exit 1. `node --test test/scripts/firebasePlistInjection.test.mjs` from `backend/`: Expected: the four new tests FAIL.
- [ ] **Step 3: Implement** the script, the Fastfile changes, the Jenkinsfile binding (one line in the Deploy stage's list, with a comment like the client key's) and the `.gitignore` line.
- [ ] **Step 4: Verify.** The shell test: Expected: `check-firebase-plist: all <n> cases passed`. `npm run test:scripts` from `backend/`: Expected: all pass, the earlier tests included. `git check-ignore -v Marauders-ios/Marauders/GoogleService-Info.plist`: Expected: prints the `.gitignore` rule. `ruby -c Marauders-ios/fastlane/Fastfile`: Expected: `Syntax OK`. From `Marauders-ios/`, `FASTLANE_SKIP_UPDATE_CHECK=1 fastlane lanes` (the Homebrew binary: this Mac's system Ruby lacks the bundler version of `Gemfile.lock`, so `bundle exec` does not start): Expected: lists `test`, `build` and `beta` with no error.

### Task 7: Docs

**Files:** modify `docs/adr/012-force-update.md`, `docs/adr/README.md`, `ARCHITECTURE.md`, `README.md`, `deployment/README.md`, `docs/ci-cd.md`, the design's status line; remove `docs/superpowers/specs/2026-11-21-force-update-design.md` and `docs/superpowers/plans/2026-11-21-force-update.md`.

- [ ] **Step 1: Write the failing doc pins** in `firebasePlistInjection.test.mjs`: `adrTwelveIsAboutFirebaseRemoteConfig` (it names `Firebase Remote Config`, `minimum_build`, `update_url`, `GoogleService-Info.plist`); the adr index row names Firebase; `README.md`, `ARCHITECTURE.md` and `deployment/README.md` contain none of `/v1/config`, `MINIMUM_BUILD`, `UPDATE_URL`, `appConfig.ts`; `README.md` names `GoogleService-Info.plist`; `ARCHITECTURE.md` names `FirebaseRemoteConfigSource` and `FirebasePlistCheckTests`; `deployment/README.md` names `minimum_build`; `docs/ci-cd.md` lists `marauders-firebase-plist` and the read-back `Payload/Marauders.app/GoogleService-Info.plist`. Run them: Expected: they FAIL.
- [ ] **Step 2: Rewrite** (before editing a doc, re-read its status lines, and afterwards scan the five docs and the new design for anything that looks like a real key or id):
  - **ADR-012**, around Firebase, keeping what is still true (the key is the build number and the exemptions, fail open and never wait, screen gate only, UITEST, the rollout rule): *Decision* (where the two numbers come from and the parse rule; the one Firebase file; the start-up guard; the plist git-ignored with the Jenkins credential and the lane check; undo is publishing 0, no deploy), *Alternatives* (the first-party Worker route: built and tested 2026-11-21, never deployed or committed, replaced before shipping because the owner chose Firebase Remote Config; `426`; iTunes lookup), *Consequences* (the owner's rollout steps, the five new known limits of the design, the limits that still hold), *Tests*, *Triggers to revisit*, *Evidence* (filled in Task 8) and *References* (the new design and plan).
  - **`docs/adr/README.md`**: the row's text. **`ARCHITECTURE.md`**: drop the `/v1/config` row and paragraph; reword the "A build can be too old to run" bullet; replace `AppConfigRepositoryTests` in the test lines and add `FirebasePlistCheckTests`, `FirebaseAppConfigRepositoryTests`, `check-firebase-plist-tests.sh` and `firebasePlistInjection.test.mjs`. **`README.md`**: drop the route row; in the iOS setup say a plain Run needs no plist and where the plist goes; add the script to the `Scripts/` tree. **`deployment/README.md`**: drop the two vars from the deploy checklist; rewrite *ยกระดับ build ขั้นต่ำ (force update)* in Thai as the console steps (publish `minimum_build` = N and `update_url`, never above the newest uploaded build; undo by publishing 0; a raise reaches a device within about an hour after a launch or foreground). **`docs/ci-cd.md`**: a `marauders-firebase-plist` Secret file row in the credentials table, the *Version / Build number* paragraph reworded, and a read-back of the plist and `CFBundleVersion` from the .ipa (`unzip -p Marauders.ipa 'Payload/Marauders.app/GoogleService-Info.plist' | plutil -extract BUNDLE_ID raw -o - -`), like the client key's.
- [ ] **Step 3: Remove the two first-party docs** only after `cmp` shows each equals its copy in the kept folder (Task 1). Change the new design's status line to: approved by the owner 2026-11-21; built and tested; not committed, deployed or in a TestFlight build.
- [ ] **Step 4: Verify.** `npm run test:scripts` from `backend/`: Expected: all pass, the doc pins included. `git grep -n "v1/config" -- README.md ARCHITECTURE.md deployment docs/ci-cd.md`: Expected: no output.

### Task 8: Gates and the proofs that need no console

**Files:** none changed here except the ADR's *Evidence* and the memory note. `$F` is `Marauders-ios/Marauders/GoogleService-Info.plist`. If a file is already there it is the owner's real plist: never overwrite, move or delete it. Then Step 3 uses it as it is, and the plist-less runs of Steps 2 and 4 are made from a scratch mirror that leaves it out (`rsync -a --delete --exclude build/ --exclude vendor/ --exclude GoogleService-Info.plist`, as in the owner's simulator-test note), saying so in the report.

- [ ] **Step 1: The suites.** The whole unit target (Task 5's count). The whole UI target in the background: Expected: 90 tests, exactly one failure, `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` (simulator-only, fails at HEAD too), so `xcodebuild` exits 65. `cd backend && npm test`; the four shell suites under `Marauders-ios/Scripts/tests/`. Expected: all green.
- [ ] **Step 2: A Production archive without the plist** (from the working tree when `$F` does not exist, else from the scratch mirror of the Files note): `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Production" -destination generic/platform=iOS -archivePath $S/Production.xcarchive -derivedDataPath $S/DerivedData-archive -clonedSourcePackagesDirPath $S/SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=`. Expected: `** ARCHIVE SUCCEEDED **`, with the Production guard passing: a build with no plist still builds.
- [ ] **Step 3: The same archive with a fixture plist.** Only if `$F` does not exist, write one with `GOOGLE_APP_ID` `1:000000000000:ios:0000000000000000`, `BUNDLE_ID` `com.somsak.Marauders`, `API_KEY` `FIXTURE-NOT-A-KEY`, `GCM_SENDER_ID` `000000000000`, `PROJECT_ID` `fixture-not-a-project`. Archive again. Expected: `GoogleService-Info.plist` is inside the built `.app` and `sh Marauders-ios/Scripts/check-firebase-plist.sh --plist <that file> --bundle-id com.somsak.Marauders` prints `firebase plist ok: com.somsak.Marauders`.
- [ ] **Step 4: The simulator, Staging, a fresh install each time.** With no plist: Expected: no crash; `log show --info --predicate 'category == "update"'` on the simulator shows `gate:`, the decision, then `firebase not started: …; the gate stays open`, in that order and after the pass check. With the fixture plist in the build: Expected: no crash, the SDK starts at that first ask and not before, and the fetch fails harmlessly (`firebase fetch failed: …`, `config refresh failed`). Check the launch log shows nothing of Firebase before the first frame.
- [ ] **Step 5: Clean up and record.** Delete a fixture you wrote and verify `test ! -e $F`. Fill ADR-012's *Evidence* with the real counts and results, and say what is not yet proved (Task 9). Update the memory note `project-feature-flags-remote-config.md` and its `MEMORY.md` line: built, tested, uncommitted, the kept folder's path, the counts. Report to the owner what to commit and in what groups; commit nothing.

### Task 9: The proof against the owner's real console (waits for the owner)

Needs the owner's plist at `$F` and their Firebase console: the project (Google Analytics off), the iOS app `com.somsak.Marauders`, the parameters `minimum_build` (Number, 0) and `update_url` (String, empty), published. Each step below is a fresh install, which clears the SDK's fetch timer.

- [ ] **Step 1:** Run Staging on the simulator. Expected: the log shows `config refreshed: minimumBuild=0` and the app runs.
- [ ] **Step 2:** The owner publishes `minimum_build` = 5 and an `update_url` on apple.com. Build `Marauders Production` for the simulator with `CURRENT_PROJECT_VERSION=2` (configuration Release-Production), install it fresh and launch. Expected: the log shows `config refreshed: minimumBuild=5` and the Update screen replaces the app.
- [ ] **Step 3:** The owner publishes `minimum_build` = 0. A fresh install. Expected: `config refreshed: minimumBuild=0` and the app runs, no screen.
- [ ] **Step 4:** Record the three results in ADR-012's *Evidence*, and say what is still unproved until the first TestFlight build: the Update button opening the link, and the Jenkins path itself (the plist credential and the read-back from the .ipa). The owner's plist stays where it is: it is git-ignored.
