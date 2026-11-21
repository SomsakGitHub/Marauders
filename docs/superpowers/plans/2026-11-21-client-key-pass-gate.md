# The Pass Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app runs only when its build-time value `MARAUDERS_CLIENT_KEY` is exactly the pass `run by pass`; any other build opens a block screen and starts nothing.

**Architecture:** `ClientKey` gains the pass, a rule (`accepts`) and a reader of this build (`appMayRun`). `MaraudersApp` asks it first thing in `init()`, before the session guard, the location monitor and the upload session, and in `body` shows `AppRootView()` for the pass and a new `ClientKeyBlockedView` otherwise. The project's mock default becomes the pass, so a plain Run from Xcode still works; Jenkins still overrides it through xcargs and its credential must hold the pass. The gate is at run time: no build ever fails.

**Tech Stack:** Swift 6.4 / Xcode 27.2 (SwiftUI, Swift Testing, iOS 27.0), a string catalog, `node:test` script tests, Markdown docs.

**Spec:** `docs/superpowers/specs/2026-11-21-client-key-pass-gate-design.md` (approved 2026-11-21, "อนุมัติ A"; read it first). It amends `docs/superpowers/specs/2026-11-21-injected-build-value-design.md`, whose build is uncommitted in the same tree.

## Global Constraints

- The pass is the exact text `run by pass` (lower case, single spaces). The app target's build setting `MARAUDERS_CLIENT_KEY` holds it in `Debug-Staging` and `Release-Production`, and the Jenkins credential `marauders-client-key` must hold it. The comparison is exact after the trimming `ClientKey.resolve` already does. Names do not change: build setting, Info.plist key and environment variable `MARAUDERS_CLIENT_KEY`; credential `marauders-client-key`.
- The gate is at run time. Nothing may fail a build the owner runs from Xcode: no Run Script phase, no change to `Scripts/check-release-config.sh`, no guard in the Fastfile. No Worker change. The value is sent nowhere.
- Nothing starts before the check: `init()` returns before `AuthLog.forwardToAppLog()`, `InstallationSessionGuard.bootstrap`, the location monitor and the uploader, and the `.backgroundTask` closure checks too.
- The value and the pass are never printed or logged, and the block screen never shows or hints at either: it says the build has no valid client key. The one log line is `client key is not the pass: nothing starts`.
- Every user-facing text is localized: `Text("…")` with a Thai text in `Localizable.xcstrings`. The catalog stays in Xcode's layout (`"key" : value`, keys in Finder order, so the new keys go directly before `"This cannot be undone."`). `Scripts/find-plain-strings.py` stays clean. The Thai wording is this plan's proposal and the owner's to review.
- Swift 6.4, Xcode 27.2, every target iOS 27.0, Swift Testing; swift-format with `Marauders-ios/.swift-format` (line length 120); `Scripts/check-layers.sh --strict` stays clean; a new Swift file in a synchronized folder needs no `project.pbxproj` edit; the app target's default isolation is MainActor, so `ClientKey` stays `nonisolated`.
- iOS tests run on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9` (the owner's order of 2026-11-15), never the phone, with `-derivedDataPath` and `-clonedSourcePackagesDirPath` in `<scratchpad>` and every `-only-testing:` argument written out. A green run shows "Test run with N tests", N above 0. `<scratchpad>` is this session's scratchpad, `/private/tmp/claude-502/-Users-tiscomacnb2486-Desktop-Marauders/43276a31-2cc1-4c66-9382-634b680b1381/scratchpad`; the earlier session's DerivedData is gone, so the first build is a full one. Backend: `cd backend && npm test`.
- Nothing is committed, pushed or deployed by this plan: the owner says when (a checkpoint stands where a commit would). Jenkins reads GitHub, so a Build Now sees this only after a push, and a Build Now uploads to TestFlight.

## Review Focus

Failure modes the spec implies and its proof list does not name, most likely first:

1. A missing, blank or other value must block, never crash and never run partly. Task 1 `anythingElseIsRefused`, and Task 3 Step 3, a real build with a wrong value.
2. Something starting before the check: the session guard, the location monitor, the upload session, or the system relaunching the app for an upload. Task 2 `theAppChecksThePassBeforeItStartsAnything`, and the unified log in Task 3 Step 3.
3. The pass with a credential's whitespace is accepted (a value pasted with a line break), while a case or spacing variant is not (`Run By Pass`, `run-by-pass`, `run by  pass`). Task 1 `thePassIsAcceptedWithSurroundingWhitespace` and `anythingElseIsRefused`.
4. A Jenkins credential still holding the old random value: every TestFlight build then opens on the block screen. The docs name the exact value (Task 3 `docsGiveTheCredentialItsExactValue`) and the read-back after a Build Now shows what a build carries; a check in the lane was offered and not chosen.
5. A tester on a Thai iPhone seeing English on the block screen. Task 2 `theBlockScreenTextsHaveThai`, and the Thai screenshot in Task 3 Step 3.

---

### Task 1: The rule, and the pass in the project

**Files:**
- Modify: `Marauders-ios/Marauders/Shared/Configuration/ClientKey.swift`, `Marauders-ios/MaraudersTests/ClientKeyTests.swift`, `Marauders-ios/Marauders.xcodeproj/project.pbxproj` (the app target's two configurations), `backend/test/scripts/clientKeyInjection.test.mjs`

**Interfaces:**
- Produces: `ClientKey.pass: String` (`"run by pass"`), `static func accepts(configured: String?) -> Bool`, `static func appMayRun() -> Bool`; the build setting value `run by pass` in both app configurations. Task 2 consumes `appMayRun()`.

- [ ] **Step 1: Write the failing tests.**
  - In `MaraudersTests/ClientKeyTests.swift` replace `theBuiltAppAlwaysCarriesAValue` with the tests below (keep the other tests, and put the array beside `missingOrDirty`); update the doc comment of the struct to say the app runs only with the pass:

    ```swift
    /// Text that only looks like the pass, the old mock, and values `resolve` already rejects.
    private static let notThePass: [String?] = [
        nil, "", "   ", "Run By Pass", "run-by-pass", "run by  pass", "run by pass please", "xrun by pass",
        "mock-client-key-local-only", "$(MARAUDERS_CLIENT_KEY)", "run by pass\nX-Evil: 1",
    ]

    @Test func thePassIsTheOneTheOwnerNamed() {
        #expect(ClientKey.pass == "run by pass")
    }

    @Test func thePassIsAcceptedWithSurroundingWhitespace() {
        #expect(ClientKey.accepts(configured: "run by pass"))
        #expect(ClientKey.accepts(configured: "  run by pass\n"))
    }

    @Test(arguments: ClientKeyTests.notThePass)
    func anythingElseIsRefused(configured: String?) {
        #expect(!ClientKey.accepts(configured: configured))
    }

    /// What a plain Run from Xcode relies on: the project's value reaches Info.plist and is the pass.
    @Test func theBuiltAppCarriesThePass() {
        #expect(ClientKey.appMayRun())
    }
    ```

  - In `backend/test/scripts/clientKeyInjection.test.mjs` add `const PASS = "run by pass";` after `CREDENTIAL` and replace the first test with:

    ```js
    test("bothAppConfigurationsHoldThePass", () => {
      const appBlocks = buildSettingBlocks(read("Marauders-ios/Marauders.xcodeproj/project.pbxproj")).filter(
        ({ settings }) => settings.includes(`${URL_SETTING} = `),
      );
      assert.deepEqual(appBlocks.map(({ name }) => name).sort(), ["Debug-Staging", "Release-Production"]);
      for (const { name, settings } of appBlocks) {
        const value = new RegExp(`^\\t\\t\\t\\t${SETTING} = "?([^";]*)"?;$`, "m").exec(settings)?.[1];
        assert.equal(value, PASS, `${name}: the app runs only with the pass, so the project must hold exactly "${PASS}"`);
      }
    });
    ```

- [ ] **Step 2: Run both and see them fail.**

  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Staging" -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' -derivedDataPath <scratchpad>/DerivedData-sim -clonedSourcePackagesDirPath <scratchpad>/SourcePackages -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/ClientKeyTests
  cd backend && node --test test/scripts/clientKeyInjection.test.mjs
  ```

  Expected: a compile error in the first (`type 'ClientKey' has no member 'pass'` or `'accepts'`); in the second `bothAppConfigurationsHoldThePass` fails with `mock-client-key-local-only !== run by pass` and the other five pass.

- [ ] **Step 3: Implement the rule** in `ClientKey.swift`: `static let pass = "run by pass"`; `static func accepts(configured: String?) -> Bool`, true exactly when `resolve(configured:)?.value == pass`; `static func appMayRun() -> Bool`, which reads `Bundle.main.object(forInfoDictionaryKey: configKey) as? String` each time and asks `accepts`. Rewrite the type's doc comment: the app runs only with the pass (`MaraudersApp` checks it first and shows a block screen otherwise); the project holds the pass in both app configurations so a plain Run from Xcode needs no setup, and Jenkins overrides it for a TestFlight build (docs/ci-cd.md); the value reaches the app the way `MARAUDERS_API_BASE_URL` does; it is printed as `<redacted>`, nothing sends it anywhere, and it is not a secret (it is in git and in the app). Leave the comments of `resolve` and `resolved` as they are.

- [ ] **Step 4: Run the Swift suite again** (the Step 2 command). Expected: everything passes except `theBuiltAppCarriesThePass` (`Expectation failed: ClientKey.appMayRun()`), because the project still holds the mock.

- [ ] **Step 5: Put the pass in the project.** In `project.pbxproj` change both `MARAUDERS_CLIENT_KEY = "mock-client-key-local-only";` lines to `MARAUDERS_CLIENT_KEY = "run by pass";`. Check: `grep -c 'MARAUDERS_CLIENT_KEY = "run by pass";' Marauders-ios/Marauders.xcodeproj/project.pbxproj` prints 2 and `grep -c 'mock-client-key-local-only' Marauders-ios/Marauders.xcodeproj/project.pbxproj` prints 0.

- [ ] **Step 6: Run both again.** Expected: `** TEST SUCCEEDED **` with "Test run with N tests", N above 0, and `ClientKeyTests` fully passed; the script test file passes all six.

- [ ] **Step 7: Checkpoint (no commit).** `git status --short` lists the four Task 1 paths beside the earlier uncommitted work; `cd Marauders-ios && xcrun swift-format lint --strict Marauders/Shared/Configuration/ClientKey.swift MaraudersTests/ClientKeyTests.swift` exits 0.

---

### Task 2: The app refuses to start without the pass

**Files:**
- Create: `Marauders-ios/Marauders/Presentation/Splash/ClientKeyBlockedView.swift`
- Modify: `Marauders-ios/Marauders/App/MaraudersApp.swift`, `Marauders-ios/Marauders/Resources/Localizable.xcstrings`, `Marauders-ios/MaraudersTests/LocalizationCatalogTests.swift`, `backend/test/scripts/clientKeyInjection.test.mjs`

**Interfaces:**
- Consumes: `ClientKey.appMayRun() -> Bool` (Task 1).
- Produces: `struct ClientKeyBlockedView: View` (no parameters); the catalog keys `This build cannot run` and `This build has no valid client key, so the app does not start.`

- [ ] **Step 1: Write the failing tests.**
  - In `LocalizationCatalogTests` (beside the other catalog tests, formatted like them) add:

    ```swift
    /// The block screen is the one screen a tester sees when the pass is wrong, so it must not be English on a Thai phone.
    @Test(.enabled(if: sourcesAreReadable))
    func theBlockScreenTextsHaveThai() throws {
        let catalog = try StringCatalogAudit(
            data: Data(contentsOf: Self.resources.appending(path: "Localizable.xcstrings")))

        for key in ["This build cannot run", "This build has no valid client key, so the app does not start."] {
            #expect(catalog.text(forKey: key, language: "th") != nil, "\(key): no Thai text in Localizable.xcstrings")
        }
    }
    ```

  - In `clientKeyInjection.test.mjs` add (and say in the header comment that the app's launch is a fifth hand-off no compiler checks):

    ```js
    test("theAppChecksThePassBeforeItStartsAnything", () => {
      const app = read("Marauders-ios/Marauders/App/MaraudersApp.swift");
      const init = app.slice(app.indexOf("init() {"), app.indexOf("var body: some Scene"));
      const gate = init.search(/guard ClientKey\.appMayRun\(\) else \{[^}]*\breturn\b[^}]*\}/);
      assert.notEqual(gate, -1, "init() must return early when ClientKey.appMayRun() is false");
      for (const started of [/AuthLog\.forwardToAppLog\(\)/, /InstallationSessionGuard\.bootstrap\(/, /AppDependencyContainer\./]) {
        assert.ok(init.search(started) > gate, `${started} must come after the pass check`);
      }
      assert.match(
        app,
        /if ClientKey\.appMayRun\(\)\s*\{\s*AppRootView\(\)\s*\}\s*else\s*\{\s*ClientKeyBlockedView\(\)\s*\}/,
        "the window shows the app only for the pass and the block screen otherwise",
      );
      const relaunch = app.slice(app.indexOf(".backgroundTask("));
      const check = relaunch.indexOf("ClientKey.appMayRun()");
      assert.ok(check !== -1 && check < relaunch.indexOf("awaitSystemEvents()"), "a relaunch for an upload must not start the uploader of a blocked build");
    });
    ```

- [ ] **Step 2: Run both and see them fail.** `cd backend && node --test test/scripts/clientKeyInjection.test.mjs` fails only the new test (`init() must return early…`). The Task 1 Step 2 Swift command with `-only-testing:MaraudersTests/LocalizationCatalogTests` fails only `theBlockScreenTextsHaveThai`, naming both keys.

- [ ] **Step 3: The block screen.** Create `Presentation/Splash/ClientKeyBlockedView.swift` in the style of `SplashView` (file header, black background, a white symbol): a decorative `Image(systemName: "lock.slash")` hidden from VoiceOver, the title `Text("This build cannot run")` with the header trait, and `Text("This build has no valid client key, so the app does not start.")`; text styles rather than fixed sizes so Dynamic Type works, centred, padded, no buttons, a `#Preview`. It must not mention the pass.

- [ ] **Step 4: The Thai texts.** In `Localizable.xcstrings` insert two entries directly before the `"This cannot be undone."` entry, in the shape of the `"Delete Account"` entry (a `th` localization whose `stringUnit` has `state` `translated`): `This build cannot run` gets `บิลด์นี้ใช้งานไม่ได้`, and `This build has no valid client key, so the app does not start.` gets `บิลด์นี้ไม่มี client key ที่ถูกต้อง แอปจึงไม่เริ่มทำงาน`. Edit the file as text, keep Xcode's layout and do not dump it through a JSON writer: `theCatalogsAreInTheLayoutXcodeWrites` is the check.

- [ ] **Step 5: Wire the gate** in `MaraudersApp.swift`. After `_ = AppLog.launchUptime` and before every other line of `init()`:

  ```swift
  // The pass (docs/ci-cd.md): a build that does not carry it starts nothing, and `body` shows the block screen.
  guard ClientKey.appMayRun() else {
      AppLog.error("app", "client key is not the pass: nothing starts")
      return
  }
  ```

  The window content becomes `if ClientKey.appMayRun() { AppRootView() } else { ClientKeyBlockedView() }`, and the `.backgroundTask(.urlSession(…))` closure begins with `guard ClientKey.appMayRun() else { return }`. Comments above the guard must not name the calls the test looks for after it.

- [ ] **Step 6: Run the tests.** `node --test test/scripts/clientKeyInjection.test.mjs` passes all seven. The Swift command with `-only-testing:MaraudersTests/LocalizationCatalogTests`, `-only-testing:MaraudersTests/StringCatalogLayoutTests` and `-only-testing:MaraudersTests/ClientKeyTests` passes: `** TEST SUCCEEDED **`, "Test run with N tests", N above 0.

- [ ] **Step 7: Gates and checkpoint (no commit).** From the repo root: `sh Marauders-ios/Scripts/check-layers.sh --strict` and `python3 Marauders-ios/Scripts/find-plain-strings.py` exit 0 and print nothing; `cd Marauders-ios && xcrun swift-format lint --strict Marauders/App/MaraudersApp.swift Marauders/Presentation/Splash/ClientKeyBlockedView.swift MaraudersTests/LocalizationCatalogTests.swift` exits 0; `git status --short` lists the Task 1 and Task 2 paths and nothing else besides the earlier uncommitted work.

---

### Task 3: Docs, then prove it with real builds

**Files:**
- Modify: `docs/ci-cd.md`, `deployment/README.md`, `README.md`, `ARCHITECTURE.md`, `Marauders-ios/fastlane/Fastfile` and `Jenkinsfile` (comments only), `backend/test/scripts/clientKeyInjection.test.mjs`

**Interfaces:**
- Consumes: the pass, the gate and the block screen (Tasks 1 and 2). Produces no code.

- [ ] **Step 1: Write the failing doc test** in `clientKeyInjection.test.mjs`:

  ```js
  test("docsGiveTheCredentialItsExactValue", () => {
    const row = read("docs/ci-cd.md").split("\n").find((line) => line.startsWith(`| \`${CREDENTIAL}\``));
    assert.ok(row?.includes(PASS), "the credentials table of docs/ci-cd.md must say the credential holds exactly the pass");
    const sentence = read("deployment/README.md").split("\n").find((line) => line.includes(`\`${CREDENTIAL}\``));
    assert.ok(sentence?.includes(PASS), "deployment/README.md must say the credential holds exactly the pass");
  });
  ```

  Run `cd backend && node --test test/scripts/clientKeyInjection.test.mjs`. Expected: this test fails, the other seven pass.

- [ ] **Step 2: The docs.** Thai in `docs/ci-cd.md` and `deployment/README.md`, English in `README.md` and `ARCHITECTURE.md`; no link to the untracked specs.
  - `docs/ci-cd.md`, the credentials table row of `marauders-client-key`: the credential must be `run by pass` exactly, and the app runs only with it. The section "ค่าที่ Jenkins ฝังให้ build": the app runs only when the value is the pass, otherwise it opens a block screen and starts nothing; the project holds the pass so a Run from Xcode needs no setup; Jenkins overrides it through the lane; the pass is not a secret (in git and in the app) and the gate shows that the value arrived, it protects nothing. The credential's Secret is exactly `run by pass`, no longer a random value. A new paragraph "ทดสอบว่า Jenkins ฝังค่าจริง": take the two `MARAUDERS_CLIENT_KEY` lines out of the project (or give them other text), a Run from Xcode then shows the block screen, Build Now with the credential gives a build that opens, and the read-back from the .ipa gives `run by pass`; put the lines back for ordinary Runs. The read-back sentence expects `run by pass`. The caveats: an Archive from Xcode carries the project's value (the pass, or a blocked app with the lines out); any other credential value, a leftover random one included, makes a build that reaches TestFlight and opens on the block screen, so read the value back after every Build Now; drop the `$` caveat (the pass has none); keep the log caveat (the value in those logs is public anyway) and the upgrade-path caveat reworded for a real value. In "รันในเครื่อง" the optional export becomes `export MARAUDERS_CLIENT_KEY="run by pass"`.
  - `deployment/README.md` (the credentials sentence): `marauders-client-key` holds `run by pass` exactly, and the app opens only with it.
  - `README.md` (the `Config/` line) and `ARCHITECTURE.md` (the bullet "The app picks its Worker at build time"): the project holds the pass `run by pass`, Jenkins overrides it, and the app runs only with it, otherwise it starts nothing and shows `ClientKeyBlockedView`; nothing sends the value anywhere.
  - Comments only: the Fastfile comment above the `client_key` lines and the Jenkinsfile comment above the binding say "the project's default (the pass)" instead of "mock"; the header comment of `ClientKeyTests` says the app runs only with the pass.

- [ ] **Step 3: Run the script tests, then the whole backend suite.** `cd backend && node --test test/scripts/clientKeyInjection.test.mjs` (all eight pass), then `cd backend && npm test`. Expected: exit 0, no `not ok`.

- [ ] **Step 4: The whole unit target.** The Task 1 Step 2 Swift command with `-only-testing:MaraudersTests`. Expected: `** TEST SUCCEEDED **`, "Test run with N tests", and no failure.

- [ ] **Step 5: Run the app on the simulator, with the pass and with a wrong value.** Everything from the repo root; report each result and say what a step could not show.
  1. `xcodebuild build` with the scheme `Marauders Staging`, the Task 1 destination and paths. Read `plutil -extract MARAUDERS_CLIENT_KEY raw -o - <scratchpad>/DerivedData-sim/Build/Products/Debug-Staging-iphonesimulator/Marauders.app/Info.plist`: it prints `run by pass`. Install and launch (the iOS Simulator tool, or `xcrun simctl install` and `launch`), take a screenshot: the app starts (splash, then the feed or sign-in), no block screen. Read the log: `xcrun simctl spawn 902C645A-22D9-47F3-86B0-3E4623B6B2A9 log show --info --last 3m --predicate 'subsystem == "<bundle id>"'` holds an `upload.bg` line `launch`.
  2. Uninstall the app, then build again with `MARAUDERS_CLIENT_KEY=wrong-value` as an extra argument of the same command. The plist now prints `wrong-value`. Install and launch, take a screenshot: the block screen with the two texts and nothing else, the app still alive (not crashed). The same log command shows `client key is not the pass: nothing starts` and no `upload.bg` line at all.
  3. Launch it again with `-AppleLanguages "(th)" -AppleLocale th_TH` (`xcrun simctl launch … <bundle id> -AppleLanguages "(th)" -AppleLocale th_TH`) and take a screenshot: the Thai texts.
  4. Rebuild without the extra argument and launch once more: the app starts again, so the project is left as it was.

- [ ] **Step 6: Production archives.** Two unsigned archives with `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Production" -destination 'generic/platform=iOS' -derivedDataPath <scratchpad>/DerivedData-archive -clonedSourcePackagesDirPath <scratchpad>/SourcePackages -archivePath <scratchpad>/<name>.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`. (a) With no override: `** ARCHIVE SUCCEEDED **` with the guard's `release config ok:` line, and `plutil -extract MARAUDERS_CLIENT_KEY raw -o - <scratchpad>/<name>.xcarchive/Products/Applications/Marauders.app/Info.plist` prints `run by pass`. (b) With the argument built as the Fastfile builds it: a scratchpad script computes xcargs from `ENV["MARAUDERS_CLIENT_KEY"]` with exactly the two Fastfile lines and runs the same command with that string appended, as one string so a shell parses it as gym does. Run it with `MARAUDERS_CLIENT_KEY=$'  run by pass\n'`. Expected: the same success and guard line, and the plist read-back equals `run by pass` (compare in the shell and print only `same`): strip and escape deliver the pass, spaces included.

- [ ] **Step 7: Mutations.** Copy each file to `<scratchpad>` first, change it, run the test named, restore the copy and check `git diff --stat` is as before. Script tests, `cd backend && node --test test/scripts/clientKeyInjection.test.mjs`: (a) delete the guard in `init()`: `theAppChecksThePassBeforeItStartsAnything`; (b) move `AuthLog.forwardToAppLog()` above the guard: the same test; (c) show `AppRootView()` without the `if`: the same test; (d) delete the check in the `.backgroundTask` closure: the same test; (e) change one project value to `run-by-pass`: `bothAppConfigurationsHoldThePass`; (f) delete the exact value from the credentials table row: `docsGiveTheCredentialItsExactValue`. Swift, the `ClientKeyTests` command: (g) make `accepts` return true for any resolved value: `anythingElseIsRefused`; (h) compare case-insensitively: `anythingElseIsRefused` (the `Run By Pass` case).

- [ ] **Step 8: The other gates and one UI smoke test.** `sh Marauders-ios/Scripts/check-layers.sh --strict` and `python3 Marauders-ios/Scripts/find-plain-strings.py` exit 0; `sh Marauders-ios/Scripts/tests/check-release-config-tests.sh` passes unchanged; swift-format lint of the five Swift files of this plan exits 0; `ruby -c Marauders-ios/fastlane/Fastfile` says `Syntax OK`; the UI test `-only-testing:MaraudersUITests/MaraudersUITestsLaunchTests/testLaunch` (the Task 1 command with `test`, the same destination and paths) passes, which shows the app still launches with the pass (the whole UI target takes 16 to 34 minutes and is not run).

- [ ] **Step 9: Final state.** `git status --short` and `git diff --stat` show only this plan's paths, the earlier uncommitted work and the untracked docs; nothing is committed. The report says what changed, the evidence per step, the Thai texts for the owner's review, and what was not run: the whole UI target, the fastlane lanes, a signed archive, a Jenkins build (so the Jenkinsfile binding stays unproven until a Build Now) and a physical iPhone.

---

## Owner-gated (not tasks)

Each needs the owner's own yes; the plan never does them.

1. **The Jenkins credential, before the next Build Now.** Manage Jenkins, Credentials, Global, Add Credentials: Secret text, ID `marauders-client-key`, Secret exactly `run by pass`. If it was already created with another value, change it. Without it the Deploy stage stops before it builds; with another value the build opens on the block screen.
2. **Commit** (suggested: one commit for this and the build-time value under it, "Let Jenkins hand the app a build-time value, and let the app run only with the pass"; the specs and plans only if the owner says so).
3. **Push.** Jenkins reads GitHub `*/main`, so it sees nothing before this.
4. **Build Now.** It uploads a TestFlight build. Then read the value back from the archived .ipa with the command in `docs/ci-cd.md`: it must be `run by pass`. To prove that Jenkins supplied it, take the two project lines out first, as the docs say.
5. **The Thai wording** of the two block-screen texts.
