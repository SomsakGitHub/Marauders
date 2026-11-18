# Thai and English Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app shows Thai or English by the iPhone's language, with an "App language" row in Settings that opens the app's page in iOS Settings, and not one English text changes.

**Architecture:** A string catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`) with `th` comes back. Every user-facing plain `String` becomes `String(localized:)` with the identical English words, so English cannot change. A hand-run script finds plain strings that creep back, guard tests pin the catalogs, the shared scheme pins the unit-test host to English, and one Settings row opens iOS Settings.

**Tech Stack:** Swift 6 and SwiftUI, Xcode string catalogs with `xcstringstool`, Swift Testing (unit), XCTest (UI), POSIX `sh` and Python 3 (the scan script and its tests).

**Spec:** `docs/superpowers/specs/2026-11-17-localization-thai-english-design.md` (approved by the owner on 2026-11-17; the experiments of the same day corrected four of its sentences, which now stand in Design items 4, 6 and 7 and in Done means).

## Baseline (measured on 2026-11-17 on a scratch mirror of b50ca29)

A clean mirror build takes 25 s and prints 71 `warning:` lines; an incremental build takes 6 to 8 s. The 2026-11-02 catalog synced against today's sources gives 234 live keys, 98 of them without Thai, and one stale key (`Retry`). The mechanisms the tasks use (the `xcstringstool` sync, `INFOPLIST_FILE`, the scheme's test arguments) were each tried that day; the spec's Design items 4, 6 and 7 say how they behave.

## Global Constraints

- English texts unchanged character for character (`’` is not `'`, `…` is not `...`). The key of a catalog entry is the English text.
- Domain and Data import Foundation only; `String(localized:)` is Foundation and already used there (`DubbingError`). The package `MaraudersAuth` keeps its English texts and gets no resources.
- Only `String(localized: "...")`, with no `comment:`, `table:` or `bundle:` (the codebase style). Interpolations become placeholders. An `Int` interpolation is formatted by the locale from 1,000 up (`1,000`), so a value that can reach 1,000 is interpolated as `String(value)` instead.
- Metric units. The Worker, the API and every stored data format do not change. Developer-only text stays English.
- Swift formatting: `xcrun swift-format format -i <file>` with `Marauders-ios/.swift-format` (4 spaces, 120 columns). A build must add no `warning:` line to the baseline of 71.
- Thai register: neutral ("คุณ", no ครับ/ค่ะ), the vocabulary of the 2026-11-02 catalog (`git show fca9a87^:Marauders-ios/Marauders/Resources/Localizable.xcstrings`).
- Every target is iOS 27.0. Tests run only on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9`, never on the phone. No worktree.
- No commit, no push, no TestFlight build until the owner says. Commit only paths named in this plan, never `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` (the owner's uncommitted edit).

## Recipes (`$SCRATCH` is the session scratchpad, `R=/Users/tiscomacnb2486/Desktop/Marauders`, `M=$SCRATCH/mirror/Marauders-ios`)

- **R1 mirror, before every build or test run.** The main checkout is never built; the mirror holds what would be committed (the owner's file at `HEAD`). First time only, also copy the `SourcePackages` folder of the Xcode DerivedData folder of Marauders that has one to `$SCRATCH/SourcePackages`, so Lottie and WhisperKit need no network.
  ```bash
  rsync -a --delete --exclude build/ --exclude vendor/ --exclude .build/ --exclude xcuserdata/ \
    --exclude Marauders/Data/API/RetryingHTTPClient.swift $R/Marauders-ios/ $M/
  git -C $R show HEAD:Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift > $M/Marauders/Data/API/RetryingHTTPClient.swift
  ```
- **R2 test run.** Read the `Test run with N tests` (unit) or `Executed N tests` (UI) line: N = 0 means the filter matched nothing and the run proves nothing. Write each `-only-testing:` argument out.
  ```bash
  cd $M && xcodebuild test -project Marauders.xcodeproj -scheme Marauders \
    -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' \
    -derivedDataPath $SCRATCH/DD -clonedSourcePackagesDirPath $SCRATCH/SourcePackages \
    -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
  ```
  Whole unit target: `-only-testing:MaraudersTests` (1265 tests at b50ca29). One UI test: `-only-testing:MaraudersUITests/MaraudersUITests/<testName>`. The whole UI target takes about 16 minutes: run it in the background.
- **R3 sync the main checkout's catalog** after R1 and a build. After a deleted or renamed source, remove `$SCRATCH/DD/Build/Intermediates.noindex/Marauders.build` first and rebuild, so no old `.stringsdata` keeps a string alive.
  ```bash
  export SCRATCH R; bash -c 'D=$SCRATCH/DD/Build/Intermediates.noindex/Marauders.build/Debug-iphonesimulator/Marauders.build/Objects-normal/arm64
  args=(); for f in "$D"/*.stringsdata; do args+=(--stringsdata "$f"); done
  xcrun xcstringstool sync "$R/Marauders-ios/Marauders/Resources/Localizable.xcstrings" "${args[@]}"'
  ```
- **R4 Thai simulator.** `UDID=$(xcrun simctl clone 902C645A-22D9-47F3-86B0-3E4623B6B2A9 "Marauders-th")` (the source must be shut down), `boot`, `bootstatus -b`, then `xcrun simctl spawn $UDID defaults write "Apple Global Domain" AppleLanguages -array th` and `... AppleLocale -string th_TH`, shut down, boot again. When done: `xcrun simctl shutdown $UDID; xcrun simctl delete $UDID`.
- **R5 checks.** `sh Marauders-ios/Scripts/check-layers.sh --strict` prints nothing; `sh Marauders-ios/Scripts/tests/check-layers-tests.sh` passes.

## Review Focus

The inputs and conditions the design implies and no task's main tests exercise; each has its test in the task named.

1. An iPhone in a language the app lacks (Japanese): the app is English, not Thai, and language names in sentences are English. The bundle picks `en` for `ja-JP` (Task 7), and `InterfaceLanguage` answers "English" for an empty or unknown list (Task 11).
2. A Thai text that changes the order of placeholders: positional specifiers (`%2$@ ... %1$@`) must pass the guard, a changed count or type must fail it (Task 7).
3. Thai text that is clipped or overlaps at a large Dynamic Type size: a UI test opens Settings at the largest size and checks the new row is reachable; the screens are looked at (Tasks 12, 13).
4. A text stored before the language changed: the fixed upload failures keep no sentence on disk (Task 3).
5. A key that only developers see has no Thai and must not block the guard, while a user-facing key without Thai must (Task 7).

## File Structure

| Create | Responsibility |
|---|---|
| `Marauders-ios/Scripts/find-plain-strings.py`, `plain-strings-allowlist.txt`, `tests/find-plain-strings-tests.sh` | Finds user-facing plain strings; its allowlist; its fixture tests (style of `check-layers-tests.sh`) |
| `Marauders-ios/Config/Info-Additions.plist` | Holds `UIPrefersShowingLanguageSettings` for `INFOPLIST_FILE` |
| `Marauders-ios/Marauders/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` | The two catalogs (English key, `th` value) |
| `Marauders-ios/Marauders/Presentation/Settings/InterfaceLanguage.swift` | Names the language the app's texts are in |
| `MaraudersTests/Support/StringCatalogAudit.swift` and `StringCatalogAuditTests.swift`, `LocalizationCatalogTests.swift`, `AppBundleLocalizationTests.swift`, `LocalizedErrorTextTests.swift`, `InterfaceLanguageTests.swift` | Guard logic and its tests, the real-catalog guards, the English pins of error texts |
| `MaraudersUITests/MaraudersThaiUITests.swift` | The Thai UI set |

Modified: the ~35 sources of Tasks 2 to 6, `Marauders.xcodeproj/project.pbxproj` (Task 8), the shared scheme (Task 10), `SettingsView.swift` and `MaraudersUITests.swift` (Task 11), `SignInWithAppleGateView.swift` (Task 12, one accessibility identifier), three docs (Task 14).

---

### Task 1: The plain-string scan

**Files:** Create the three files above. The prototype that found 117 literals in 42 files on the unchanged tree is `$SCRATCH/survey/scan.py` (throwaway; rewrite it under the tests).

**Interfaces:** Produces `python3 Marauders-ios/Scripts/find-plain-strings.py [--base DIR] [--allowlist FILE]`. Roots are `$BASE/Marauders` and `$BASE/Packages/MaraudersAuth/Sources`; `BASE` defaults to the folder above `Scripts`. It prints one `path:line: "text"` per hit (path relative to `BASE`), then `N plain strings` or `OK: no plain strings`, and exits 1 when N > 0. Allowlist lines are `path|text  # reason`, or `path|*` for a whole file; `#` starts a comment line.

The rule: read Swift tokens (skip `//` and `/* */` comments, `#Preview { }` bodies and `"""` literals; an interpolation `\(...)` becomes `§`, and a literal inside one is read on its own). For each literal take the innermost enclosing call name (last dotted part) and the label in front of it. Skip it when the call is a localizable API (`Text Button Label Toggle Section TextField SecureField Picker Menu NavigationLink LabeledContent Link ProgressView ContentUnavailableView DisclosureGroup Stepper Gauge GroupBox ShareLink PhotosPicker Tab Marker Annotation LocalizedStringKey LocalizedStringResource NSLocalizedString navigationTitle navigationBarTitle accessibilityLabel accessibilityHint accessibilityValue alert confirmationDialog searchable help badge accessibilityAction`) and the label is none, `title`, `titleKey`, `prompt` or `message`; when the label is `localized`, `systemImage`, `systemName`, `named`, `forKey`, `id`, `identifier`, `subsystem`, `category` or `forHTTPHeaderField`; or when the call is logging (`AppLog` methods, `print`), an assertion (`assert`, `assertionFailure`, `precondition`, `preconditionFailure`, `fatalError`), `accessibilityIdentifier`, or a `URL` or `URLRequest` initializer. Report what is left when it is text-like: (a) it starts with a capital letter followed by a lowercase letter, or with `%` or `§`, and holds a word of two or more lowercase letters after a space (`Sign in required`, `§ km`, `%.0f m away`); or (b) it is one capitalised word with at least two more lowercase letters, with an optional `…` (`Download`, `Finishing…`).

- [ ] **Step 1: Write `tests/find-plain-strings-tests.sh`** in the style of `check-layers-tests.sh` (a fake `Marauders/` tree per case, `begin`/`put`/`run`/`expect_text`/`expect_no_text`, a summary line, exit 1 on failure). Cases, each a Swift snippet and the expectation:

| Case | Snippet | Expect |
|---|---|---|
| plain message | `let m = "Sign in required"` | hit, exit 1 |
| localizable view | `Text("Sign in required")`; `Button("Retry") {}`; `.navigationTitle("Settings")` | none |
| conditional of two literals | `Text(flag ? "A is on" : "A is off")` | none |
| localized call, two lines | `String(\n    localized: "Sign in required")` | none |
| verbatim text | `Text(verbatim: "Sign in required")` | hit |
| fallback | `x ?? "Could not load"` | hit |
| format string | `String(format: "%.0f m away", m)` | hit |
| leading placeholder | `"\(n) km"` | hit |
| one word | `let t = "Download"` | hit |
| codes and names | `"OK"`, `"TH"`, `"GET"`, `"UITEST"`, `"MelSpectrogram"`, `"mp4"`, `"settings.root"` | none |
| logging, assertion, identifier | `AppLog.info("upload", "Upload OK here")`; `precondition(x, "Bad state here")`; `.accessibilityIdentifier("Some id here")` | none |
| preview and comment | `#Preview { let s = "Hello there world" }`; `// "Sign in required"` | none |
| nested literal | `"\(flag ? "A is on" : "A is off") now"` | no crash |
| allowlist line | hit text plus `path|Sign in required  # why` | none, exit 0 |
| allowlist whole file | `path|*` | none |
| clean tree | nothing to report | `OK: no plain strings`, exit 0 |

- [ ] **Step 2: Run it** (`sh Marauders-ios/Scripts/tests/find-plain-strings-tests.sh`). Expected: every case fails (the script does not exist).
- [ ] **Step 3: Implement `find-plain-strings.py`** to the rule and the interface above, until Step 1's script passes.
- [ ] **Step 4: Run the script on the real tree.** Expected: roughly 110 to 120 hits in about 40 files (the survey's prototype found 117 in 42). Save the list to `$SCRATCH/worklist.txt`.
- [ ] **Step 5: Fill the allowlist** with what the scan reports and no viewer reads, each entry with its reason. Expected entries: whole files `Marauders/Data/Repositories/UITestCommentRepository.swift`, `UITestFeedRepository.swift`, `UITestUserProfileRepository.swift`, `Marauders/Composition/UITestRejectedSession.swift`, `DebugSessionFault.swift`, `Marauders/Shared/Configuration/DevLogin.swift`, `Marauders/Shared/Logging/AppLogStore.swift`; single literals in `Data/API/APIConfiguration.swift` (two configuration errors), `Data/API/MultipartBodyWriter.swift` (two header lines), `Packages/MaraudersAuth/Sources/MaraudersAuthData/AuthRoute.swift` ("API URL must be https:// with no path"), `Presentation/Map/BackgroundLocationMonitor.swift` and `Presentation/Upload/UploadVideoViewModel.swift` (the `holdAwake` reasons "Share location" and "Upload video"), `Presentation/Settings/LanguageModelsView.swift` ("Download" and "Try Again", arguments of a `LocalizedStringKey` parameter); and the six English texts of the package, `Packages/MaraudersAuth/Sources/MaraudersAuth/AuthAPIClientProtocol.swift` (five) and `SignInWithAppleUseCase.swift` ("Invalid account"), which stay English because `AuthViewModel.userFacingMessage(for:)` maps them (Task 4), so a new package text shows up in the scan and reminds the next developer of that mapping. Re-run: what is left (about 100 hits, about 75 distinct texts in about 35 files) is the worklist of Tasks 2 to 6.
- [ ] **Step 6: Checkpoint.** `git status --short` shows only the three new files (and the owner's four old entries).

### Task 2: Error texts of Domain and Data

**Files:** Create `MaraudersTests/LocalizedErrorTextTests.swift`. Modify the `errorDescription` of: `Domain/Entities/Comment.swift` (`CommentError`), `ClipLike.swift` (`ClipLikeError`), `FollowList.swift` (`FollowListError`), `FriendLocation.swift` (`LocationSharingError`), `UserFollow.swift` (`UserFollowError`); `Domain/Repositories/UserLocationRepository.swift` (`UserLocationAPIError`); `Domain/UseCases/UpdateAvatarUseCase.swift` (`UpdateAvatarError`); `Domain/Services/ClipUploading.swift` (`ClipUploadError`); `Data/API/VideoUploadAPIClient.swift` (`VideoUploadAPIError`), `UserProfileAPIClient.swift` (`UserProfileAPIError`), `HTTPClient.swift` (`HTTPClientError`), `FeedAPIClient.swift` (`FeedAPIError`), `TokenRefreshingHTTPClient.swift` (`SessionRefreshUnavailableError`); `Data/Services/VideoExportService.swift` (`VideoExportError`). Each path is under `Marauders-ios/Marauders/`.

**Interfaces:** Produces `LocalizedErrorTextTests.everyErrorKeepsItsEnglishText()`, one row `(label, actual, expected)` per case of the enums above, expected texts copied from the source as it is now (about 45 rows; `@MainActor` like the neighbouring suites).

- [ ] **Step 1: Write `LocalizedErrorTextTests`** (a `static let rows: [(String, String?, String)]`, one `#expect(actual == expected, Comment(rawValue: label))` per row).
- [ ] **Step 2: R1, R2** with `-only-testing:MaraudersTests/LocalizedErrorTextTests`. Expected: PASS (it pins today's text, N = 1 test).
- [ ] **Step 3: Convert** every returned literal to `String(localized: "<same text>")`, interpolations kept (`Server responded with status \(code)`). A value that can reach 1,000 (the comment length limit) is interpolated as `String(max)`.
- [ ] **Step 4: R2** with `LocalizedErrorTextTests`, `FollowListUseCaseTests`, `FollowListViewModelTests`, `FriendLocationsViewModelTests`, `TokenRefreshingHTTPClientTests`, `VideoUploadAPIClientTests`, `UserProfileAPIClientTests`, `FeedAPIClientTests`, `SignOutLocationSharingTests`, `StopLocationSharingOnSignOutUseCaseTests`. Expected: PASS, still the same English.
- [ ] **Step 5: Run the scan.** Expected: none of these files is in the list. `git status` shows only these paths.

### Task 3: Upload texts

**Files:** Modify `Data/Upload/UploadRecord.swift` (the six fixed texts of `UploadFailure.message`), `Data/Upload/BackgroundClipUploader+Completion.swift` (the `Upload failed (status N)` fallback of `workerMessage`), `Presentation/Upload/UploadVideoViewModel.swift` ("Set the clip location before uploading", "Upload complete — opening feed", "Couldn’t read location — try again" twice, "Finishing…", "Uploading… N%"), `Presentation/Upload/UploadVideoView.swift:210` ("Couldn’t read video — try a shorter clip"), `Presentation/Upload/ClipLocationPickerViewModel.swift` ("Enter 2–120 characters to search", "No places found — try a name, city or address", "Search failed — try again"). Test: `MaraudersTests/UploadRecordTests.swift`, `ClipLocationPickerViewModelTests.swift`.

**Interfaces:** Produces `UploadRecordTests.fixedFailuresStoreNoSentence()`: encode `.sessionEnded .unavailable .rateLimited .interrupted .responseLost .bodyMissing` with `JSONEncoder` and expect the JSON to hold none of the six English sentences (Review Focus 4).

- [ ] **Step 1: Pin what no test pins.** `UploadRecordTests`, `UploadVideoViewModelTests` and `UploadVideoViewModelUploadTests` already pin the upload texts; `searchRejectsShortQuery` already pins the first picker text; add cases to `ClipLocationPickerViewModelTests` for "No places found — try a name, city or address" (`search()` with a stub that finds nothing) and "Search failed — try again" (a stub that throws), with the stub of `lateSearchCannotReplaceNewQueryResults` as the model. Add `fixedFailuresStoreNoSentence`.
- [ ] **Step 2: R1, R2** with `UploadRecordTests`, `ClipLocationPickerViewModelTests`. Expected: PASS.
- [ ] **Step 3: Convert** the literals to `String(localized:)`. `Uploading… \(percent)%` keeps its `Int`. The line in `UploadVideoView.swift` has no unit test (it sits in a `Task` closure of the view); it is a one-line change covered by the scan.
- [ ] **Step 4: Look for other stored text.** Read `UploadRecordStore`, `DubbedAudioReportMemory`, `DetectedLanguageMemo`, `FeedStartupCache` and the `UserDefaults` keys for a human sentence kept on disk. Expected: only `UploadFailure.connection/.rejected/.serverError`, the accepted exception. Write down anything else.
- [ ] **Step 5: R2** with `UploadRecordTests`, `UploadRecordStoreTests`, `UploadVideoViewModelTests`, `UploadVideoViewModelUploadTests`, `ClipLocationPickerViewModelTests`, `BackgroundClipUploaderCompletionTests`, `BackgroundClipUploaderLaunchTests`, `BackgroundClipUploaderStartTests`. Expected: PASS.

### Task 4: Sign-in texts

**Files:** Modify `Packages/MaraudersAuth/Sources/MaraudersAuth/SignInWithAppleUseCase.swift` (`SignInError` becomes `public`; its text stays English), `Marauders/Presentation/Auth/AuthViewModel.swift`, `SignInLocationViewModel.swift`, `SignInSheet.swift`. Test: `MaraudersTests/AuthViewModelTests.swift`, `SignInLocationViewModelTests.swift`.

**Interfaces:** `AuthViewModel.userFacingMessage(for: Error) -> String` (private static, as now) maps `AuthAPIError.invalidIdentityToken` to "Sign in could not be verified", `.invalidResponse` to "Invalid sign-in response", `.refreshRejected` to "Your session has ended. Please sign in again.", `.serverError(500...599)` to "The service is temporarily unavailable. Please try again.", `.serverError(other)` and any non-localized error to "Sign in failed. Please try again.", `SignInError.invalidAccount` to "Invalid account", any other `LocalizedError` to its description; every text through `String(localized:)`.

- [ ] **Step 1: Pin.** In `AuthViewModelTests` add three cases through `FailingAuthAPIClient(error:)` and `completeSignIn`: `invalidIdentityToken`, `invalidResponse`, `refreshRejected`, each expecting the text above. Pin each `SignInLocationViewModel` text that `SignInLocationViewModelTests` does not (denied, restricted, timeout, failed lookup, no recent location).
- [ ] **Step 2: R1, R2** with `AuthViewModelTests`, `SignInLocationViewModelTests`. Expected: PASS (the package's own descriptions are the same English).
- [ ] **Step 3: Convert.** `SignInError` to `public`. `AuthViewModel`: the mapping above and the three assignments (`Sign in failed` twice, `Sign in was not completed`). `SignInLocationViewModel`: every message literal (seven distinct texts; "Set location access to Always in Settings before signing in." appears four times). `SignInSheet`: the three literals passed to `SignInWithAppleGateView` become `String(localized:)` ("Sign in", "Welcome to Marauders", "Sign in with Apple to continue."); the gate view is unchanged.
- [ ] **Step 4: R2** with the same suites plus `AuthAPIClientTests`, `TokenRefreshingHTTPClientTests`. Expected: PASS. The guest sign-in UI tests run in Task 15.

### Task 5: Map, profile and player texts

**Files (under `Marauders/Presentation/`):** `Map/MapClipProximity.swift`, `Map/NearMeRadius.swift`, `Map/MapSearchBar.swift`, `Map/FriendLocationsViewModel.swift`, `Upload/ClipLocationPickerView.swift`, `Profile/FollowListViewModel.swift`, `ProfileViewModel.swift`, `PublicProfileViewModel.swift`, `Feed/Playback/FeedPlayerEngine.swift`. Test: `MaraudersTests/MapClipProximityTests.swift`, create `NearMeRadiusTests.swift`.

**Interfaces (my calls):**
- `MapClipProximity.formattedDistance(_:) -> String`: below 1,000 m `String(localized: "\(String(format: "%.0f", meters)) m away")`; above `String(localized: "\(String(format: "%.1f", meters / 1_000)) km away")`. The number keeps `String(format:)` so English is identical even at a half-way value (a later language with a decimal comma would use `.formatted`).
- `NearMeRadius.label` is `String(localized: "\(kilometers) km")`; `emptyClipsMessage` is `String(localized: "No clips within \(kilometers) km")`.
- `MapSearchBar.prompt` defaults to `String(localized: "Search clips")`.
- `ClipLocationPickerView.coordinateLabel` is `String(localized: "\(latitudeText), \(longitudeText) — tap the map to move the pin")` with the two numbers from `String(format: "%.5f", ...)`.
- `FriendLocationsViewModel.setSharing` falls back to `String(localized: "Couldn't change location sharing")` (the alert title in `SettingsView` is the same key).
- `FollowListViewModel.loadMessage(for:)`, `ProfileViewModel`, `PublicProfileViewModel` and the three `failPlayback` texts ("URL is not secure", "Couldn’t load video", "Playback failed") use `String(localized:)`.

- [ ] **Step 1: Pin first.** `NearMeRadiusTests`: `.fiveKm.label == "5 km"`, `.twentyFiveKm.emptyClipsMessage == "No clips within 25 km"`. In `MapClipProximityTests` add `449.5` and `450.5` metres (the `%.0f` results) beside the existing 450 and 2,500. `grep` the other texts in `MaraudersTests`; add a case to `FollowListViewModelTests`, `ProfileViewModelTests`, `PublicProfileViewModelTests`, `FriendLocationsViewModelTests` or `FeedPlayerEngineTests` for each one no test pins.
- [ ] **Step 2: R1, R2** with those suites. Expected: PASS.
- [ ] **Step 3: Convert** as above, then format the touched files.
- [ ] **Step 4: R2** with the same suites. Expected: PASS.

### Task 6: Remove the dead Thai sentences, then close phase 1

**Files:** Modify `Marauders/Domain/Services/ClipAudioInspecting.swift` (delete `ClipAudioAssessment.message`, lines 15 to 22) and `MaraudersTests/FastClipAudioInspectorTests.swift` (delete the two `result.message.contains(...)` assertions, lines 45 and 59).

- [ ] **Step 1: Delete** the property and both assertions, then build: the compiler shows any other reader. Expected: the build succeeds.
- [ ] **Step 2: R2** with `FastClipAudioInspectorTests`. Expected: PASS.
- [ ] **Step 3: Check** from `Marauders-ios/`: `grep -rnP '[\x{0E00}-\x{0E7F}]' Marauders Packages --include='*.swift'`. Expected: two hits, both doc comments in `Domain/Entities/ListeningLanguage.swift` (lines 41 and 46), none in code.
- [ ] **Step 4: Phase gate.** R1, then the whole unit target. Expected: all pass, N = 1265 plus the new cases. The scan prints `OK: no plain strings`. R5. The build log has 71 `warning:` lines.
- [ ] **Step 5:** `git status --short` lists exactly: the scan script, allowlist and test (Task 1); the converted sources, `LocalizedErrorTextTests.swift`, `NearMeRadiusTests.swift` and the edited suites (Tasks 2 to 6). Tell the owner; commit 1, "strings made localizable, English unchanged", waits for their word while the work goes on.

### Task 7: Guard tests (red first)

**Files:** Create `MaraudersTests/Support/StringCatalogAudit.swift`, `StringCatalogAuditTests.swift`, `LocalizationCatalogTests.swift`, `AppBundleLocalizationTests.swift`.

**Interfaces:** Produces
```swift
struct StringCatalogAudit {
    struct Problem: Equatable, CustomStringConvertible { let key: String; let reason: String }
    init(data: Data) throws
    func problems(language: String = "th") -> [Problem]   // live keys only; reasons "no Thai text", "placeholders differ"
    func missing(languages: [String], forKeys keys: [String]) -> [Problem]   // for the Info.plist catalog
}
```
A key is live unless `extractionState` is `stale`, and needs Thai unless `shouldTranslate` is `false`. Thai counts as present when `localizations.th.stringUnit.value` is non-empty (or `variations` is non-empty). Placeholders: `%%` is ignored; the English key's placeholders are numbered in order; a Thai text without positions must list the same conversion types in the same order, a Thai text with positions (`%2$@`) must use positions for all and map each position to the English type.

- [ ] **Step 1: Write `StringCatalogAuditTests`** (fixtures as JSON strings): `keyWithoutThaiIsReported`; `emptyThaiIsReported`; `samePlaceholdersPass` (`%@ has %lld clips` and `%@ มี %lld คลิป`); `missingPlaceholderIsReported` (`%lld` only); `swappedTypesWithoutPositionsAreReported` (`%@ has %lld` and `%lld มี %@`); `positionalReorderPasses` (`%2$lld คลิปของ %1$@`); `percentLiteralIsIgnored` (`100%% sure %@`); `dontTranslateKeyIsExempt`; `staleKeyIsExempt`; `infoPlistLanguagesAreChecked`.
- [ ] **Step 2: Run** (R1, R2). Expected: build error, `StringCatalogAudit` not found.
- [ ] **Step 3: Implement `StringCatalogAudit`**; run. Expected: PASS.
- [ ] **Step 4: Write the real guards**, `@MainActor`. The two catalog guards read the committed catalogs next to the `MaraudersTests` folder (`URL(fileURLWithPath: #filePath)` minus the file name and the folder name, then `Marauders/Resources/...`) and run only on a simulator (`.enabled(if:)`): `LocalizationCatalogTests.everyLiveKeyHasThaiWithMatchingPlaceholders` and `.infoPlistCatalogHasEnglishAndThaiForEveryUsageText` (the keys are every `NS...UsageDescription` in `Bundle.main.infoDictionary`). The bundle guards in `AppBundleLocalizationTests`: `.theAppShipsEnglishAndThai` (`Bundle.main.localizations` holds `en` and `th`); `.languagesMapToTheAppsTwoLanguages` (`Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences:)` gives `th` for `["th-TH"]` and `en` for `["ja-JP"]`, Review Focus 1); `.theLanguageRowIsAlwaysOffered` (`UIPrefersShowingLanguageSettings` is `true`); `.everyUsageTextHasThaiInTheBuiltBundle` (`th.lproj`'s `InfoPlist` table differs from the English text for each key and holds a Thai character); `.theTestHostRunsInEnglish` (`Bundle.main.preferredLocalizations.first == "en"`, message "the shared scheme's test arguments pin English").
- [ ] **Step 5: Run them.** Expected: all FAIL (no catalog, no `th.lproj`, no plist key) except `theTestHostRunsInEnglish`, which passes on an English simulator and goes red only on the Thai one in Task 10. Save the failure list.

### Task 8: Project plumbing and the first catalog

**Files:** Modify `Marauders.xcodeproj/project.pbxproj`; create `Marauders-ios/Config/Info-Additions.plist`, `Marauders/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings`.

- [ ] **Step 1: pbxproj.** In `knownRegions` add `th` after `Base`. In both configurations of the app target add `INFOPLIST_FILE = "Config/Info-Additions.plist";` on the line before `INFOPLIST_KEY_MARAUDERS_API_BASE_URL`. `Config/Info-Additions.plist` is a plist whose only key is `UIPrefersShowingLanguageSettings` with `<true/>`.
- [ ] **Step 2: Restore the catalog:** `git show fca9a87^:Marauders-ios/Marauders/Resources/Localizable.xcstrings > Marauders-ios/Marauders/Resources/Localizable.xcstrings`.
- [ ] **Step 3: R1, a build, R3.** Expected: the file is rewritten in Xcode's format (`"key" : value`), about 300 keys, `Retry` stale. Delete stale keys with a short Python load/edit/dump, then run R3 again so the file is back in Xcode's format; running R3 a third time must change nothing (`git diff --stat` identical).
- [ ] **Step 4: `InfoPlist.xcstrings`** (source `en`): the six keys `NSCameraUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSSpeechRecognitionUsageDescription` with an `en` value copied by script from `project.pbxproj`; the build settings stay, and are the English base.
- [ ] **Step 5: R2** with `AppBundleLocalizationTests`. Expected: `theAppShipsEnglishAndThai`, `languagesMapToTheAppsTwoLanguages`, `theLanguageRowIsAlwaysOffered`, `theTestHostRunsInEnglish` pass; `everyUsageTextHasThaiInTheBuiltBundle` fails until Task 9.

### Task 9: The Thai texts and the table for the owner

- [ ] **Step 1:** List the live keys without Thai from the catalog into `$SCRATCH/needs-thai.txt` (about 170).
- [ ] **Step 2: Write `$SCRATCH/thai.json`** (English key to Thai). Rules: placeholders kept (positional when the order changes); a language name inside a sentence takes "ภาษา" before it ("เสียง AI ภาษา%@"); "คุณ", never ครับ/ค่ะ; sign-in words as in the old catalog ("เข้าสู่ระบบ"); "Marauders" stays Latin; `…` kept; units "กม." and "ม.". The six permission texts get Thai too.
- [ ] **Step 3: Merge by script** into the catalog (`stringUnit` `state` `translated`) and into `InfoPlist.xcstrings`. Mark `"shouldTranslate": false` on a key only when every place it appears is developer-only (`Presentation/Debug/**`, an `#if DEBUG` block, the two test sign-in buttons): expected "Upload or open the feed — events appear here", "Log", "Copy All", "Paste into chat or Notes", "Copy Message", "View Log", "Sign in as test user (%@)", "Complete test sign in"; `grep` each before marking (`OK` and `Clear` are shared). Run R3 twice; the second run changes nothing.
- [ ] **Step 4: R2** with `LocalizationCatalogTests`, `AppBundleLocalizationTests`, `StringCatalogAuditTests`. Expected: PASS (Task 7's red turns green).
- [ ] **Step 5: Write `$SCRATCH/thai-review-table.md`** (`| English | Thai |` for the new keys and the six permission texts) and give the owner its full path. Changes they ask for go through `thai.json`, Step 3 and Step 4 again.

### Task 10: Pin the unit-test host to English

**Files:** Modify `Marauders.xcodeproj/xcshareddata/xcschemes/Marauders.xcscheme`.

- [ ] **Step 1: Red.** R4, then R2 with `AppBundleLocalizationTests/theTestHostRunsInEnglish` and `-destination ...id=<the Thai UDID>`. Expected: FAIL (`preferredLocalizations` is `th`).
- [ ] **Step 2: Pin.** In `<TestAction>` change `shouldUseLaunchSchemeArgsEnv = "YES"` to `"NO"` and put this after `</Testables>`:
  ```xml
        <CommandLineArguments>
           <CommandLineArgument argument = "-AppleLanguages (en)" isEnabled = "YES"></CommandLineArgument>
           <CommandLineArgument argument = "-AppleLocale en_US" isEnabled = "YES"></CommandLineArgument>
        </CommandLineArguments>
  ```
  (in Xcode's one-attribute-per-line layout, as in the scheme's other elements).
- [ ] **Step 3: Green.** The same run on the Thai simulator. Expected: PASS. Then the whole unit target on the Thai simulator. Expected: PASS. Delete the clone (R4).
- [ ] **Step 4:** the whole unit target on the English simulator. Expected: PASS.

### Task 11: The "App language" row

**Files:** Create `Marauders/Presentation/Settings/InterfaceLanguage.swift`, `MaraudersTests/InterfaceLanguageTests.swift`; modify `Presentation/Settings/SettingsView.swift`, `MaraudersUITests/MaraudersUITests.swift`.

**Interfaces:** Produces `enum InterfaceLanguage { static func currentName(preferredLocalizations: [String] = Bundle.main.preferredLocalizations) -> String }`: the first code that is not `Base`, named in its own language and capitalized (`Locale(identifier: code).localizedString(forLanguageCode: code)`); `"English"` for an empty list or a code that has no name. The row is the first `Section` of `SettingsView`: a `Button` whose label is `LabeledContent` with `Label("App language", systemImage: "globe")` and the value `Text(InterfaceLanguage.currentName())`, action `if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }`, as the existing "Allow location access Always" button does, `.accessibilityIdentifier("settings.appLanguage")`, footer `Text("Marauders uses your iPhone's language. To change it for Marauders only, open iOS Settings; the app restarts when you do.")`. The row needs no chevron.

- [ ] **Step 1: Write `InterfaceLanguageTests`:** `["th"]` gives `ไทย`; `["en"]` gives `English`; `["Base", "th"]` gives `ไทย`; `[]` and `["zz"]` give `English` (Review Focus 1). Run. Expected: FAIL (type missing).
- [ ] **Step 2: Implement; run.** Expected: PASS.
- [ ] **Step 3: UI test red.** In `MaraudersUITests` add `testSettingsShowsTheAppLanguageRowAndOpensIOSSettings`: `launchApp()`, `openSettings(app)`, the button `settings.appLanguage` exists, its label contains "App language" and "English"; tap it and `XCTAssertNotEqual(app.state, .runningForeground)` after waiting up to 10 s (drop that last assertion if it proves flaky, and keep Step 5). Run it (R2, UI). Expected: FAIL (no row).
- [ ] **Step 4: Add the row**; format; run the UI test and `InterfaceLanguageTests`. Expected: PASS.
- [ ] **Step 5: Look at iOS Settings.** Install the mirror's app on the simulator, launch it with the UI-test arguments, tap the row, take a screenshot of the Settings page that opens. Expected: a Language row under Marauders. If it is missing, add a second preferred language to the simulator and look again; if it is still missing, add `CFBundleLocalizations` (`en`, `th`) to `Config/Info-Additions.plist` and look again (spec, Risks). Write down which case shows the row, for the owner.

### Task 12: Thai UI tests

**Files:** Create `MaraudersUITests/MaraudersThaiUITests.swift`; modify `Presentation/Auth/SignInWithAppleGateView.swift` (`.accessibilityIdentifier("signin.locationMessage")` on the `Text(message)` of the location gate). The Thai file has its own launch helper that copies `launchApp(extraArguments:)` of `MaraudersUITests` (private there): arguments `["UITEST", "-AppleLanguages", "(th)", "-AppleLocale", "th_TH"] + extra`, and `launchEnvironment["UITEST"] = "1"`. English tab and row labels cannot be used, so tabs are chosen by position (the Debug tab bar shows Feed, Map, Profile, Upload and More; Settings is the first row under More) and elements by identifier. Assertions say "holds a Thai character" and "does not contain the English text", so a wording change in the owner's review breaks nothing.

- [ ] **Step 1: Write four tests:** `testTheFirstFourTabsAreThai` (the labels of `tabBars.buttons` 0 to 3 each hold a Thai character); `testSettingsShowsTheAppLanguageRowInThai` (More, first row, then `settings.appLanguage`: its label holds a Thai character and its value contains `ไทย`); `testASignInMessageComposedInAViewModelIsThai` (extra arguments `UITEST_STREAMING_FEED`, `UITEST_GUEST`, `UITEST_LOCATION_DENIED`, the route of `testSignInRequiresLocationPermission`: tap `feed.chooseAudio`, wait for `signin.locationMessage`; its label holds a Thai character and does not contain "Set location access"; that message is a converted plain string, Task 4); `testThaiHoldsAtTheLargestTextSize` (extra arguments `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`; open Settings; scroll until `settings.appLanguage` is hittable; Review Focus 3).
- [ ] **Step 2: Run** (R2, `-only-testing:MaraudersUITests/MaraudersThaiUITests`). Expected: N = 4; `testASignInMessageComposedInAViewModelIsThai` fails (the identifier does not exist yet), the other three pass.
- [ ] **Step 3: Add the identifier** and run again. Expected: PASS, N = 4. Then run `testSignInRequiresLocationPermission` of `MaraudersUITests`. Expected: PASS (the English route is unchanged).

### Task 13: Look at the Thai screens

- [ ] **Step 1:** Install the mirror's app on the 27.2 simulator and launch it with `UITEST -AppleLanguages (th) -AppleLocale th_TH` through `xcrun simctl launch` (the bundle id is in `project.pbxproj`; the simulator control tool taps and takes the screenshots); screenshots of the feed, map, upload, profile, settings, language models, listening-language picker (its summary for "Automatic" must read in Thai, Risks section), the sign-in sheet (`UITEST_GUEST`), the comments sheet and an alert; again after `xcrun simctl ui <id> content_size accessibility-extra-extra-extra-large`. Save to `$SCRATCH/thai-screens/`.
- [ ] **Step 2:** Read each screenshot; list English leftovers, clipped or overlapping Thai, wrong grammar around language names. Fix in the catalog (or the layout, for example `lineLimit` or `minimumScaleFactor` only where a label clips), re-run Task 9 Steps 3 and 4.
- [ ] **Step 3: Review gate.** Give the owner the table's path and the screenshots' folder. Edits they ask for go back through Task 9.

### Task 14: Docs

**Files:** `deployment/AI_DUBBING.md` line 130; `ARCHITECTURE.md`; `README.md` lines 17 and 190.

- [ ] **Step 1:** `AI_DUBBING.md`: replace the "Interface language" bullet with one that says the app's own texts are English or Thai by the iPhone's language (or the language chosen for Marauders in iOS Settings), and that language names in sentences follow it through `ListeningLanguage.interfaceLocale`.
- [ ] **Step 2:** `ARCHITECTURE.md`: the Settings tab bullet gains the App language row; a new `### Localization` section before `### Swift 6 concurrency` says where the catalogs and `Config/Info-Additions.plist` live, how to add a string (write `String(localized:)` or a literal in a SwiftUI view; R3 command; the Thai; the guard tests), the plain-string rule and `python3 Marauders-ios/Scripts/find-plain-strings.py`, the English pin of the unit tests and the Thai UI set; the Tests section gets the new counts and the scan script's test command.
- [ ] **Step 3:** `README.md`: the Settings row of the feature table and the "แท็บ Settings" paragraph name the new row, in Thai.

### Task 15: Final verification

- [ ] **Step 1:** R1, then in order: the whole unit target (expected: all pass); the whole UI target in the background (expected: 57 tests, 56 pass, the known red `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn`); R5; both script test files; the scan (`OK`); R3 once more (expected: no diff).
- [ ] **Step 2:** An unsigned Release archive: `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme Marauders -configuration Release -destination 'generic/platform=iOS' -derivedDataPath $SCRATCH/DD-release -archivePath $SCRATCH/out.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` from the mirror. Expected: `** ARCHIVE SUCCEEDED **`; `plutil -p` of the app's Info.plist shows `UIPrefersShowingLanguageSettings`; `en.lproj` and `th.lproj` are in the bundle.
- [ ] **Step 3:** Update the memory notes (`project-english-only-app.md`, the index line) with what was built, the experiment findings (the spec's Design items 4, 6 and 7) and what is still the owner's.
- [ ] **Step 4:** `git status --short` lists only the paths of this plan plus the owner's old entries. Offer the three commits, each on the owner's word, never pushing: (1) Tasks 1 to 6 (scan script and its tests, converted sources, pins); (2) Tasks 7 to 10 (guard tests, `project.pbxproj`, `Config/`, both catalogs, the scheme); (3) Tasks 11 to 14 (`InterfaceLanguage`, `SettingsView`, UI tests, docs).
