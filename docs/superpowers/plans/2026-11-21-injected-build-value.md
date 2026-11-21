# One Build-Time Value Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app holds one build-time value, `MARAUDERS_CLIENT_KEY`, that Jenkins overrides when it builds, while a mock default in the project lets the app run from Xcode with no setup.

**Architecture:** A user-defined build setting on the app target (a mock default in both configurations) reaches Info.plist through `Config/Info-Additions.plist`, exactly as `MARAUDERS_API_BASE_URL` does, and a small value type, `ClientKey`, reads it. Jenkins binds a credential to the environment variable of the same name, the fastlane lane `build` passes it to xcodebuild, and a build setting given on the command line overrides the project's. No Worker change, no build guard.

**Tech Stack:** Swift 6.4 / Xcode 27.2 (Swift Testing, iOS 27.0), fastlane (Ruby), a Jenkins declarative pipeline, `node:test` script tests.

**Spec:** `docs/superpowers/specs/2026-11-21-injected-build-value-design.md` (approved 2026-11-21; read it first).

## Global Constraints

- Names, exact: the build setting, the Info.plist key and the environment variable are `MARAUDERS_CLIENT_KEY`; the Jenkins credential is `marauders-client-key` (Secret text), bound to the variable `MARAUDERS_CLIENT_KEY` in the `Deploy to TestFlight` stage only.
- The default is one made-up token, the same in `Debug-Staging` and `Release-Production`, matching `^mock-[A-Za-z0-9-]+$`: `mock-client-key-local-only`. The repository is public: no real value in a tracked file, a test or a doc; tests use throwaway values.
- Nothing may fail a build the owner runs from Xcode: no new Run Script phase, no change to `Scripts/check-release-config.sh`, no guard. No Worker change. The value is sent nowhere.
- The value is never printed or logged: `ClientKey` prints `<redacted>`; Staging's log screen says only `client key: set` or `client key: missing`, as `Text(verbatim:)`.
- Swift 6.4, Xcode 27.2, every target iOS 27.0, Swift Testing; swift-format with `Marauders-ios/.swift-format` (line length 120); `Scripts/check-layers.sh` stays clean; a new Swift file in a synchronized folder needs no `project.pbxproj` edit; the app target's default actor isolation is MainActor, so a type that may be used off the main actor is `nonisolated`.
- iOS tests run on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9` (the owner's order of 2026-11-15), never the phone, with `-derivedDataPath` and `-clonedSourcePackagesDirPath` in the scratchpad and every `-only-testing:` argument written out; a green run shows "Test run with N tests", N above 0. Backend: `cd backend && npm test`.
- Nothing is committed, pushed or deployed by this plan: the owner says when (a checkpoint stands where a commit would). A push deploys nothing; Jenkins reads GitHub, so a Build Now sees this only after a push, and a Build Now uploads to TestFlight.

## Review Focus

Failure modes the spec implies and its proof list does not name, most likely first:

1. A setting that never expanded: Info.plist holds the literal `$(MARAUDERS_CLIENT_KEY)` (a target or configuration without the setting). The app must read it as none, never as a key. Task 1 `aMissingOrDirtyValueIsNone` and `theBuiltAppAlwaysCarriesAValue`.
2. A Jenkins value with a space, a `$`, a quote or a trailing line break (a credential pasted with a newline). The build must receive the value exactly, without the break. Task 2 `theFastfilePassesTheValueOnlyWhenJenkinsGaveOne`, and Task 3 Step 4, a real build.
3. A configuration of the app target with no default (one added later), or a default that is not the made-up token (a real value committed). Task 2 `bothAppConfigurationsGiveTheValueAMadeUpDefault`.
4. The Deploy stage not binding the credential, or binding it in a stage that does not build. Task 2 `theJenkinsfileBindsTheCredentialInTheDeployStageOnly`.
5. A Production build made without Jenkins (an Archive from Xcode) or from an empty credential carries the mock, and nothing fails: the accepted cost. Task 2 writes it down with the read-back command, and `docsListTheCredentialAndTheReadBack` pins that.

---

### Task 1: The app holds the value and shows that it has it

**Files:**
- Create: `Marauders-ios/Marauders/Shared/Configuration/ClientKey.swift`, `Marauders-ios/MaraudersTests/ClientKeyTests.swift`
- Modify: `Marauders-ios/Config/Info-Additions.plist`, `Marauders-ios/Marauders.xcodeproj/project.pbxproj` (the app target's two configurations), `Marauders-ios/Marauders/Presentation/Debug/DebugLogView.swift`

**Interfaces:**
- Produces: `nonisolated struct ClientKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable` with `static let configKey = "MARAUDERS_CLIENT_KEY"`, `let value: String`, `static func resolve(configured: String?) -> ClientKey?` and `static func resolved() -> ClientKey?`. Task 2 uses only the setting's name.

- [ ] **Step 1: Write the failing tests** in `MaraudersTests/ClientKeyTests.swift` (`import Foundation`, `import Testing`, `@testable import Marauders`; `struct ClientKeyTests` with `private let key = "throwaway-client-key-for-the-tests"`):

  ```swift
  @Test func theConfiguredValueIsUsed() {
      #expect(ClientKey.resolve(configured: key)?.value == key)
  }

  @Test func surroundingWhitespaceIsTrimmed() {
      #expect(ClientKey.resolve(configured: "  \(key)\n")?.value == key)
  }

  // nil and blanks: a build without the setting. The literal: a setting that never expanded. The rest: values that
  // would break a header or a command line.
  @Test(arguments: [nil, "", "   ", "\n", "$(MARAUDERS_CLIENT_KEY)", "a\nb", "a\r\nX-Evil: 1", "a\u{0}b"] as [String?])
  func aMissingOrDirtyValueIsNone(configured: String?) {
      #expect(ClientKey.resolve(configured: configured) == nil)
  }

  @Test func itNeverPrintsItsValue() throws {
      let resolved = try #require(ClientKey.resolve(configured: key))
      var dumped = ""
      dump(resolved, to: &dumped)
      for text in [String(describing: resolved), String(reflecting: resolved), "\(resolved)", dumped] {
          #expect(!text.contains(key))
      }
  }

  // What a plain Run from Xcode relies on: the project's default reaches Info.plist and the app reads it.
  @Test func theBuiltAppAlwaysCarriesAValue() {
      #expect(ClientKey.resolved() != nil)
  }
  ```

- [ ] **Step 2: Run the suite and see it fail.** Expected: a compile error, `cannot find 'ClientKey' in scope`.

  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Staging" -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' -derivedDataPath <scratchpad>/DerivedData-sim -clonedSourcePackagesDirPath <scratchpad>/SourcePackages -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/ClientKeyTests
  ```

- [ ] **Step 3: Implement `ClientKey`** in `Shared/Configuration/ClientKey.swift`, shaped like `APIBaseURL` (same folder, header comment style) with the redaction of the cancelled branch's `ClientSecret` (`.claude/worktrees/client-secret/Marauders-ios/Marauders/Shared/Configuration/ClientSecret.swift`, in a local worktree of the cancelled branch that is not on GitHub; for reference only). `resolve(configured:)` trims whitespace and newlines and returns nil for a blank value, a value that starts with `$(` and a value with a control character (`rangeOfCharacter(from: .controlCharacters)`). `resolved()` reads `Bundle.main.object(forInfoDictionaryKey: configKey) as? String`. `description` and `debugDescription` are `ClientKey(value: <redacted>)`; `customMirror` is `Mirror(self, children: ["value": "<redacted>"], displayStyle: .struct)`. A doc comment says what the value is (a mock the project holds, Jenkins overrides) and that nothing sends it anywhere yet.

- [ ] **Step 4: Add the build setting and the plist key.**
  - `project.pbxproj`: after each of the two `MARAUDERS_API_BASE_URL = "…";` lines (the app target's `Debug-Staging` and `Release-Production`; four tabs of indent; Xcode keeps the settings sorted, so the new line sits between it and `MARKETING_VERSION`) add `MARAUDERS_CLIENT_KEY = "mock-client-key-local-only";`. Check: `grep -c 'MARAUDERS_CLIENT_KEY' Marauders-ios/Marauders.xcodeproj/project.pbxproj` prints 2.
  - `Config/Info-Additions.plist`: after the base-URL entry add the key `MARAUDERS_CLIENT_KEY` with the string `$(MARAUDERS_CLIENT_KEY)` and a one-line comment saying the project holds a mock for plain Runs and Jenkins overrides it (docs/ci-cd.md).

- [ ] **Step 5: Staging's log screen.** In `DebugLogView.swift`, inside the existing `#if DEBUG` block, add `private var clientKeyCaption: String` returning `"client key: set"` when `ClientKey.resolved()` is not nil and `"client key: missing"` otherwise, and make the subtitle `Text(verbatim: "\(apiHostCaption) · \(clientKeyCaption)")`. No catalog key: the texts are verbatim and `Scripts/plain-strings-allowlist.txt` already covers the whole file.

- [ ] **Step 6: Run the suite again** (the Step 2 command). Expected: `** TEST SUCCEEDED **`, "Test run with N tests" with N above 0, and the five tests of `ClientKeyTests` passed.

- [ ] **Step 7: Checkpoint (no commit).** From the repo root: `git status --short` lists exactly the five Task 1 paths (and the untracked docs); `cd Marauders-ios && xcrun swift-format lint --strict Marauders/Shared/Configuration/ClientKey.swift Marauders/Presentation/Debug/DebugLogView.swift MaraudersTests/ClientKeyTests.swift` exits 0; `sh Marauders-ios/Scripts/check-layers.sh --strict` exits 0 and prints nothing.

---

### Task 2: Jenkins hands its value to the build

**Files:**
- Create: `backend/test/scripts/clientKeyInjection.test.mjs`
- Modify: `Marauders-ios/fastlane/Fastfile`, `Jenkinsfile`, `docs/ci-cd.md`, `deployment/README.md`, `README.md`, `ARCHITECTURE.md`

**Interfaces:**
- Consumes: the setting `MARAUDERS_CLIENT_KEY` and its default `mock-client-key-local-only` in both app configurations (Task 1).
- Produces: the environment variable `MARAUDERS_CLIENT_KEY`, read by the lane `build` and set by Jenkins from the credential `marauders-client-key`. No Swift consumer.

- [ ] **Step 1: Write the failing script tests** in `backend/test/scripts/clientKeyInjection.test.mjs`, in the style of `noRetiredBuildNames.test.mjs` (`node:test`, `node:assert/strict`, `REPO = path.resolve(BACKEND_DIR, "..")` with `BACKEND_DIR` from `../../scripts/lib/targets.mjs`, a `read(relative)` helper). Five tests, each reading the file it names:
  1. `bothAppConfigurationsGiveTheValueAMadeUpDefault`: split `Marauders-ios/Marauders.xcodeproj/project.pbxproj` into `buildSettings = { … };` blocks and the `name = …;` line after each; keep the blocks that hold `MARAUDERS_API_BASE_URL` (the app target's two); their names are exactly `Debug-Staging` and `Release-Production`; each holds `MARAUDERS_CLIENT_KEY = "<token>";` with a token matching `/^mock-[A-Za-z0-9-]+$/`; the two tokens are equal.
  2. `infoAdditionsHandsTheBuildSettingToInfoPlist`: `Marauders-ios/Config/Info-Additions.plist` matches `/<key>MARAUDERS_CLIENT_KEY<\/key>\s*<string>\$\(MARAUDERS_CLIENT_KEY\)<\/string>/`.
  3. `theFastfilePassesTheValueOnlyWhenJenkinsGaveOne`: `Marauders-ios/fastlane/Fastfile` matches `/^require "shellwords"$/m`, `/ENV\["MARAUDERS_CLIENT_KEY"\]\.to_s\.strip/` and `/xcargs <<\s*"MARAUDERS_CLIENT_KEY=#\{Shellwords\.escape\(\w+\)\}"\s+unless\s+\w+\.empty\?/`.
  4. `theJenkinsfileBindsTheCredentialInTheDeployStageOnly`: with `at = jenkinsfile.indexOf("stage('Deploy to TestFlight')")` (asserted not -1), the text from `at` on includes `string(credentialsId: 'marauders-client-key', variable: 'MARAUDERS_CLIENT_KEY')` and the text before `at` does not include `marauders-client-key`.
  5. `docsListTheCredentialAndTheReadBack`: `docs/ci-cd.md` includes `` `marauders-client-key` `` and `plutil -extract MARAUDERS_CLIENT_KEY raw`.

- [ ] **Step 2: Run them and see 3, 4 and 5 fail.** `cd backend && node --test test/scripts/clientKeyInjection.test.mjs`. Expected: tests 1 and 2 pass (they pin Task 1), tests 3, 4 and 5 fail.

- [ ] **Step 3: The Fastfile.** Add `require "shellwords"` as the first line. In the lane `build`, directly after the `CURRENT_PROJECT_VERSION` line, add a comment (the value is the mock build value of docs/ci-cd.md; Jenkins passes the credential `marauders-client-key`; `strip` so a credential pasted with a line break cannot end the command line; `escape` because the value reaches a shell) and exactly:

  ```ruby
  client_key = ENV["MARAUDERS_CLIENT_KEY"].to_s.strip
  xcargs << "MARAUDERS_CLIENT_KEY=#{Shellwords.escape(client_key)}" unless client_key.empty?
  ```

  Run `ruby -c Marauders-ios/fastlane/Fastfile`. Expected: `Syntax OK`.

- [ ] **Step 4: The Jenkinsfile.** In the `Deploy to TestFlight` stage's `withCredentials`, after the `asc-issuer-id` line, add `string(credentialsId: 'marauders-client-key', variable: 'MARAUDERS_CLIENT_KEY')` with a one-line comment above it (fastlane passes it to the build as a build setting).

- [ ] **Step 5: The docs.** Thai in `docs/ci-cd.md` and `deployment/README.md`, English in `README.md` and `ARCHITECTURE.md`; no link to the untracked spec.
  - `docs/ci-cd.md`: a row for `marauders-client-key` in the credentials table of "ขั้นที่ 5" (Secret text; used in Deploy; without it the Deploy stage stops before it builds); a section after "Version / Build number" on the value Jenkins injects: what it is (a mock the project holds so a plain Run needs nothing; Jenkins overrides it through the lane `build`; it is baked into Info.plist at build time and is not secret), how to create the credential (made-up letters and digits, for example `openssl rand -hex 16`), how to read it back from the archived .ipa (`unzip -p Marauders.ipa 'Payload/Marauders.app/Info.plist' | plutil -extract MARAUDERS_CLIENT_KEY raw -o - -`; Production has no log screen), the plain caveats (an Archive from Xcode and an empty credential both carry the mock and nothing fails; Jenkins masks a bound credential in its console, but a local run prints the xcodebuild command with the value) and the upgrade path (once the value is real, take the default out of git into a git-ignored xcconfig and add a guard then); in "รันในเครื่อง" an optional `export MARAUDERS_CLIENT_KEY=…` line beside the `ASC_*` exports.
  - `deployment/README.md`: add `marauders-client-key` to the credentials Jenkins needs (Deploy) and ` · client key: set|missing` to the bullet about the Log tab's subtitle.
  - `README.md` (the `Config/` line of the tree): the key joins `MARAUDERS_API_BASE_URL`: a mock in the project, overridden by Jenkins.
  - `ARCHITECTURE.md` (the bullet "The app picks its Worker at build time"): one sentence: a second build-time value, `MARAUDERS_CLIENT_KEY` (read by `ClientKey`), takes the same path; the project holds a mock default, Jenkins overrides it through xcargs from the credential `marauders-client-key`, and the app only holds it.

- [ ] **Step 6: Run the script tests, then the whole backend suite.** `cd backend && node --test test/scripts/clientKeyInjection.test.mjs` (5 pass), then `cd backend && npm test`. Expected: exit 0, no `not ok`.

- [ ] **Step 7: Checkpoint (no commit).** `git status --short` lists the Task 1 paths and the Task 2 paths and nothing else (besides the untracked docs).

---

### Task 3: Prove it with real builds and the gates

No new code. Every command runs from the repo root; `<scratchpad>` is this session's scratchpad. Report each result, and say what a step could not show.

- [ ] **Step 1: The whole unit target.** The Task 1 Step 2 command with `-only-testing:MaraudersTests` in place of the suite. Expected: `** TEST SUCCEEDED **`, "Test run with N tests" and `ClientKeyTests` among the suites, no failure.

- [ ] **Step 2: Run the Staging app on the simulator.** `xcodebuild build` with the scheme `Marauders Staging` and the same destination and paths. Read the built app's Info.plist: `plutil -extract MARAUDERS_CLIENT_KEY raw -o - <scratchpad>/DerivedData-sim/Build/Products/Debug-Staging-iphonesimulator/Marauders.app/Info.plist` prints `mock-client-key-local-only`. Install and launch it with the iOS Simulator tool, take a screenshot: the app starts. If the Log tab is reachable without signing in, its subtitle ends `client key: set`; if it is behind sign-in, say so.

- [ ] **Step 3: A plain Production archive, no override.** `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Production" -destination 'generic/platform=iOS' -derivedDataPath <scratchpad>/DerivedData-archive -clonedSourcePackagesDirPath <scratchpad>/SourcePackages -archivePath <scratchpad>/plain.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`. Expected: `** ARCHIVE SUCCEEDED **` with the guard's `release config ok:` line, and the same `plutil -extract` on `<scratchpad>/plain.xcarchive/Products/Applications/Marauders.app/Info.plist` prints the mock.

- [ ] **Step 4: The same archive with the argument built as the Fastfile builds it.** In a scratchpad script (`inject-archive.rb`), compute the xcargs from `ENV["MARAUDERS_CLIENT_KEY"]` with exactly the two Fastfile lines and `exec` the Step 3 command with that string appended (one string, so a shell parses it as gym's does), with `-archivePath <scratchpad>/injected.xcarchive`. Run it with `MARAUDERS_CLIENT_KEY=$'  jenkins injected-$value\n'`. Expected: the archive succeeds with the guard's line, and the plist read-back equals `jenkins injected-$value` (compare in the shell, print only `same`). If Xcode itself mangles the `$`, keep the space case, write `$` down in `docs/ci-cd.md` as a character to avoid, and say so in the report.

- [ ] **Step 5: Mutations.** Copy each file to `<scratchpad>` first, change it, run `cd backend && node --test test/scripts/clientKeyInjection.test.mjs`, restore the copy and check `git diff --stat` is as before. Expected: each mutation fails the test named. (a) Delete the `MARAUDERS_CLIENT_KEY` line of one app configuration in `project.pbxproj`: test 1. (b) Change both defaults to `sk-live-looking-value`: test 1. (c) Delete `.strip` from the Fastfile, and separately `Shellwords.escape`: test 3. (d) Move the Jenkinsfile binding into the `Resolve Swift packages` credentials: test 4.

- [ ] **Step 6: The other gates.** `sh Marauders-ios/Scripts/check-layers.sh --strict` and `python3 Marauders-ios/Scripts/find-plain-strings.py` exit 0; `sh Marauders-ios/Scripts/tests/check-release-config-tests.sh` passes unchanged; the swift-format command of Task 1 Step 7 exits 0; `cd backend && npm test` exits 0.

- [ ] **Step 7: Final state.** `git status --short` and `git diff --stat` show only the Task 1 and Task 2 paths and the untracked docs; nothing is committed. The report says what changed, the evidence per step, and what was not run: the UI target (no UI test reads the Log subtitle; searched), the fastlane lanes, a signed archive and a Jenkins build, so the Jenkinsfile binding itself is unproven until a Build Now.

---

## Owner-gated (not tasks)

Each needs the owner's own yes; the plan never does them.

1. **The Jenkins credential, before the next Build Now.** Manage Jenkins, Credentials, Global, Add Credentials: Secret text, ID `marauders-client-key`, Secret a made-up value (`openssl rand -hex 16` makes one). Without it the Deploy stage stops before it builds.
2. **Commit** (suggested: one commit, "Let Jenkins hand the app a build-time value, with a mock default for Xcode"; the design and this plan only if the owner says so).
3. **Push.** Jenkins reads GitHub `*/main`, so it sees nothing before this.
4. **Build Now.** It uploads a TestFlight build. Then read the value back from the archived .ipa with the command in `docs/ci-cd.md`: it must be the credential's value, not the mock.
