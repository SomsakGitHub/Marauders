# App Environments (Staging and Production builds) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app two named builds, Staging (the build run from Xcode, with the in-app log and every Debug aid) and Production (what TestFlight and the App Store ship, with none of them), separated by build configuration and scheme, both on the one production backend.

**Architecture:** The two build configurations are renamed in place (`Debug` to `Debug-Staging`, `Release` to `Release-Production`), so every setting and the `DEBUG` condition stay as they are, and two shared schemes map the actions onto them. The in-app log (`DebugLogView` and the upload banner's *View Log* button) moves inside `#if DEBUG`, and the existing Release guard also fails a Production build whose executable holds a Debug-only type. CI, tests and docs follow the new names.

**Tech Stack:** Xcode project file and scheme XML, Swift 6 / SwiftUI, POSIX shell tests, Node 22 `node:test`, fastlane (Ruby), Markdown.

**Spec:** `docs/superpowers/specs/2026-11-20-app-environments-design.md` (approved by the owner on 2026-11-20, "อนุมัติ"). Executors read both files.

## Global Constraints

- Configuration names: **`Debug-Staging`** (was `Debug`) and **`Release-Production`** (was `Release`). The debug side's name must contain "Debug": Xcode gives the local package `MaraudersAuth` the `DEBUG` flag only then (spiked: a configuration named `Staging` built the app but not the package, and the build failed on `DevAuthAPIClient`).
- Scheme names: **`Marauders Staging`** and **`Marauders Production`**. The old `Marauders` scheme goes away.

  | Scheme | Run, Analyze | Test | Profile, Archive |
  |---|---|---|---|
  | `Marauders Staging` (the old scheme, moved; keeps both test targets and the launch arguments `-AppleLanguages (en)` and `-AppleLocale en_US`) | `Debug-Staging` | `Debug-Staging` | `Release-Production` |
  | `Marauders Production` (the app only, no test targets) | `Release-Production` | `Release-Production` (no testables) | `Release-Production` |

- Every list's default configuration is `Release-Production` (a command line that names none gets Production).
- Unchanged: bundle id `com.somsak.Marauders`; `MARAUDERS_API_BASE_URL` is `https://marauders-api.js6ctz7gtj.workers.dev` in both configurations; the phase name `Run Script release config check` and the success line `release config ok: <url>` (docs, Jenkins logs and tests read them); `AppLogStore` keeps recording in every build; no other `#if DEBUG` code moves; no new dependency; Staging behaves exactly as Debug does today.
- Production must not contain the types `DebugLogView` (the in-app log) and `DevAuthAPIClient` (the dev login). The guard checks the built executable for both.
- The design left three things to the builder; decided here: the guard's error line is `error: the executable <path> contains <Type>, a Debug-only type: a Production build must carry neither the in-app log nor the dev login`; the tracked `xcschememanagement.plist` is updated (Staging first); the doc edits follow the file map's order.
- Nothing is committed or pushed. Never stage anything: move the scheme with plain `mv`, never `git mv`. Never touch the owner's uncommitted `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` or the untracked `docs/superpowers/plans/2026-11-17-session-core-package.md` and `docs/superpowers/specs/2026-11-17-session-core-module-design.md`.
- Xcode runs only on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9`, from a scratch mirror, one `xcodebuild` at a time. No cloud step, no secret printed, no `db:purge`.
- Docs keep each file's language: Thai in `README.md`, `docs/ci-cd.md`, `deployment/README.md`; English in `ARCHITECTURE.md` and the ADR. Where a doc line names an app build as an environment (which Worker it talks to, what it carries), say Staging or Production; where it names the compiler flag (`#if DEBUG`, "a Debug build stops here"), leave it, since `Debug-Staging` is a Debug build.
- Swift: swift-format clean (`Marauders-ios/.swift-format`); the body of `#if DEBUG` is indented one level, as in `ContentView.swift`.
- Baselines to meet again (earlier ledger, `.superpowers/sdd/2026-11-19-environments/progress.md`): unit target 1347 tests in 134 suites; UI target 79 executed, 78 passed, with one known simulator-only red (`testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn`, a system Translate sheet); guard shell tests 16 cases before this plan; backend `test:scripts` 106 before it.

## Review Focus

Failure modes the design implies that no task would test unless named here; each gets its test in the task named.

1. **The guard reads a file that must exist when its phase runs.** An `analyze` or an archive may not produce the executable the way a build does. A guard that fails closed there breaks an archive for nothing; one that fails open passes an archive that carries the log. Tests: Task 2 (a case for a missing executable, the phase declares the executable as an input) and Task 4 (`analyze` and an unsigned archive of `Marauders Production` pass, and the archive's executable holds neither type).
2. **A guard that checks nothing.** A type renamed or moved leaves a needle that matches nothing, and the build passes. Test: Task 2 (every needle is declared in the Swift sources; mutated once to see it fail).
3. **A command line that names no configuration** gets each list's default, which must be Production. Test: Task 1.
4. **Archiving or profiling from the Staging scheme** must produce the Production build. Test: Task 1 (the Staging scheme's Profile and Archive actions).
5. **A stale command** (`-scheme Marauders`, `-configuration Release`) in a doc, a CI file or a test comment fails with "scheme not found" at the worst moment, in a Jenkins run. Test: Task 3.

## Run conventions

- `REPO=/Users/tiscomacnb2486/Desktop/Marauders`, `WORK=$REPO/.superpowers/sdd/2026-11-20-app-environments` (git-ignored: the ledger `progress.md`, the BASE snapshot, the review diff). Use absolute paths in every command (the shell's working directory drifts). Backend commands are `cd $REPO/backend && …` in one command.
- Work happens in the main checkout, uncommitted, touching only the paths each task lists. Xcode builds and tests run from a mirror in the session scratchpad (`SCRATCH` = that directory; keep its `DerivedData` and `SourcePackages`, a cold first build takes many minutes). Re-sync before every Xcode command:

```bash
rsync -a --delete --exclude '.DS_Store' --exclude '/Marauders-ios/build/' --exclude '/Marauders-ios/vendor/' --exclude '/Marauders-ios/.bundle/' --exclude 'xcuserdata/' --exclude '.swiftpm/' --exclude '.build/' "$REPO/Marauders-ios" "$SCRATCH/repo/"
mkdir -p "$SCRATCH/repo/backend" && cp "$REPO/backend/environments.json" "$SCRATCH/repo/backend/environments.json"
P="$SCRATCH/repo/Marauders-ios/Marauders.xcodeproj"
DEST='platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9'
xcodebuild build -project "$P" -scheme "Marauders Staging" -destination "$DEST" \
  -derivedDataPath "$SCRATCH/DerivedData" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages"
```

  For tests, `xcodebuild test … -scheme "Marauders Staging" -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:<target>` and read the `Test run with N tests` line (N above 0; a filter that matches nothing still prints `** TEST SUCCEEDED **`). Keep each log in a file and read its tail.
- **Checkpoint step** (last step of every task): `git -C $REPO status --short` lists only this task's paths, the earlier uncommitted work of the environments rework, the owner's untouched `RetryingHTTPClient.swift` and the untracked docs. No commit; the grouping is at the end.

## File map

| File | Responsibility |
|---|---|
| `backend/test/scripts/iosEnvironments.test.mjs` | Modify: reads the project file, the schemes, the guard script and the Swift sources, and fails on drift |
| `backend/test/scripts/noRetiredBuildNames.test.mjs` | Create: fails when a written-down command names a retired scheme or configuration |
| `Marauders-ios/Marauders.xcodeproj/project.pbxproj` | Modify: configuration names, the three Run Script phases, the guard phase's executable argument and input |
| `Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders.xcscheme` | Move (`mv`) to `Marauders Staging.xcscheme` and edit |
| `Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders Production.xcscheme` | Create |
| `Marauders-ios/Marauders.xcodeproj/xcuserdata/tiscomacnb2486.xcuserdatad/xcschemes/xcschememanagement.plist` | Modify: the tracked scheme order |
| `Marauders-ios/Scripts/check-release-config.sh`, `Scripts/tests/check-release-config-tests.sh` | Modify: the executable check |
| `Marauders-ios/Marauders/Presentation/Debug/DebugLogView.swift`, `CopyableStatusBanner.swift` | Modify: `#if DEBUG` |
| `Marauders-ios/fastlane/Fastfile`, `Jenkinsfile` | Modify: scheme and configuration names |
| `Marauders-ios/MaraudersTests/LanguageDetectionDeviceTests.swift`, `MaraudersUITests/MaraudersThaiUITests.swift`, `MaraudersAccessibilityUITests.swift`, `MaraudersUITests.swift` | Modify: comments only |
| `README.md`, `ARCHITECTURE.md`, `docs/ci-cd.md`, `deployment/README.md`, `docs/adr/010-environments.md` | Modify: the new names, the new behaviour, an ADR amendment |

---

### Task 1: Two configurations and two schemes

**Files:** the first six rows of the file map except the guard and the Swift files; Test: `backend/test/scripts/iosEnvironments.test.mjs`.

**Interfaces:**
- Produces: the configuration names and the scheme names above, and the three phases keyed on `"$CONFIGURATION" = "Release-Production"` (lint and layer check skip it, the guard runs only for it). Tasks 2 to 4 use these strings verbatim.

- [ ] **Step 0: Snapshot the BASE.** Before the first edit: `mkdir -p $WORK/base && cd $REPO && rsync -aR backend/test/scripts/iosEnvironments.test.mjs Marauders-ios/Marauders.xcodeproj/project.pbxproj Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders.xcscheme Marauders-ios/Marauders.xcodeproj/xcuserdata/tiscomacnb2486.xcuserdatad/xcschemes/xcschememanagement.plist Marauders-ios/Scripts/check-release-config.sh Marauders-ios/Scripts/tests/check-release-config-tests.sh Marauders-ios/Marauders/Presentation/Debug/DebugLogView.swift Marauders-ios/Marauders/Presentation/Debug/CopyableStatusBanner.swift Marauders-ios/fastlane/Fastfile Jenkinsfile Marauders-ios/MaraudersTests/LanguageDetectionDeviceTests.swift Marauders-ios/MaraudersUITests/MaraudersThaiUITests.swift Marauders-ios/MaraudersUITests/MaraudersAccessibilityUITests.swift Marauders-ios/MaraudersUITests/MaraudersUITests.swift README.md ARCHITECTURE.md docs/ci-cd.md deployment/README.md docs/adr/010-environments.md $WORK/base/`. The final review diffs against it, so it holds only this plan's changes. Create the ledger `$WORK/progress.md` with `# SDD ledger — plan: docs/superpowers/plans/2026-11-20-app-environments.md` as its first line.
- [ ] **Step 1: Write the failing tests** in `backend/test/scripts/iosEnvironments.test.mjs`. Add `readdirSync` to the `node:fs` import and these constants after `URL_SETTING`:

```js
const SCHEMES_DIR = path.join(IOS_DIR, "Marauders.xcodeproj", "xcshareddata", "xcschemes");
const STAGING_CONFIGURATION = "Debug-Staging";
const PRODUCTION_CONFIGURATION = "Release-Production";
const STAGING_SCHEME = "Marauders Staging";
const PRODUCTION_SCHEME = "Marauders Production";
```

  Rename the two existing build tests to `the Staging build of the app is built for the environment the Staging builds use` and `the Production build of the app is built for production`, and make them read `appConfiguration(STAGING_CONFIGURATION)` and `appConfiguration(PRODUCTION_CONFIGURATION)` (their assertions stay). Update the header comment and the `DEBUG_ENVIRONMENT` comment: Release becomes Production, Debug becomes Staging (`Debug-Staging`, the DEBUG flag); the constant keeps its name. Add:

```js
/** What each action of a scheme builds with, e.g. { TestAction: "Debug-Staging", … }, and the scheme's text. */
function schemeConfigurations(schemeName) {
  const xml = readFileSync(path.join(SCHEMES_DIR, `${schemeName}.xcscheme`), "utf8");
  const actions = {};
  for (const match of xml.matchAll(/<(TestAction|LaunchAction|AnalyzeAction|ProfileAction|ArchiveAction)\s+buildConfiguration = "([^"]+)"/g)) {
    actions[match[1]] = match[2];
  }
  return { xml, actions };
}

test("the project has exactly two configurations, Debug-Staging and Release-Production, in each of its four lists", () => {
  const names = parseBuildConfigurations(readFileSync(PBXPROJ, "utf8")).map((configuration) => configuration.name);
  assert.deepEqual(names.sort(), [...Array(4).fill(STAGING_CONFIGURATION), ...Array(4).fill(PRODUCTION_CONFIGURATION)]);
});

test("a build that names no configuration gets Production, the default of every list", () => {
  const defaults = [...readFileSync(PBXPROJ, "utf8").matchAll(/^\t\t\tdefaultConfigurationName = (.+);$/gm)].map((match) => unquote(match[1]));
  assert.deepEqual(defaults, Array(4).fill(PRODUCTION_CONFIGURATION));
});

test("the shared schemes are exactly Marauders Staging and Marauders Production", () => {
  const files = readdirSync(SCHEMES_DIR).filter((name) => name.endsWith(".xcscheme")).sort();
  assert.deepEqual(files, [`${PRODUCTION_SCHEME}.xcscheme`, `${STAGING_SCHEME}.xcscheme`]);
});

test("Marauders Staging runs, tests and analyzes as Staging, and profiles and archives as Production", () => {
  const { actions, xml } = schemeConfigurations(STAGING_SCHEME);
  assert.deepEqual(actions, {
    TestAction: STAGING_CONFIGURATION,
    LaunchAction: STAGING_CONFIGURATION,
    AnalyzeAction: STAGING_CONFIGURATION,
    ProfileAction: PRODUCTION_CONFIGURATION,
    ArchiveAction: PRODUCTION_CONFIGURATION,
  });
  assert.match(xml, /BuildableName = "MaraudersTests\.xctest"/);
  assert.match(xml, /BuildableName = "MaraudersUITests\.xctest"/);
  assert.match(xml, /argument = "-AppleLanguages \(en\)"/);
  assert.match(xml, /argument = "-AppleLocale en_US"/);
});

test("Marauders Production builds every action as Production and has no test target", () => {
  const { actions, xml } = schemeConfigurations(PRODUCTION_SCHEME);
  assert.deepEqual(actions, {
    TestAction: PRODUCTION_CONFIGURATION,
    LaunchAction: PRODUCTION_CONFIGURATION,
    AnalyzeAction: PRODUCTION_CONFIGURATION,
    ProfileAction: PRODUCTION_CONFIGURATION,
    ArchiveAction: PRODUCTION_CONFIGURATION,
  });
  assert.equal(xml.includes("<TestableReference"), false);
  assert.match(xml, /BuildableName = "Marauders\.app"/);
});

test("the Run Script phases that look at the configuration look at Release-Production, never at Release", () => {
  const scripts = [...readFileSync(PBXPROJ, "utf8").matchAll(/^\t\t\tshellScript = (".*");$/gm)]
    .map((match) => match[1])
    .filter((script) => script.includes("$CONFIGURATION"));
  assert.equal(scripts.length, 3);
  for (const script of scripts) {
    assert.ok(script.includes(`\\"${PRODUCTION_CONFIGURATION}\\"`), script);
    assert.equal(script.includes('\\"Release\\"'), false, script);
  }
});
```

- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/iosEnvironments.test.mjs` — Expected: FAIL. The two renamed tests report `expected exactly one Debug-Staging configuration for com.somsak.Marauders, found 0` (and the Production twin), the configuration and default tests report the old names, the scheme tests report a missing `Marauders Staging.xcscheme` or the old file list, the phase test reports the old `\"Release\"`. No syntax error and no failure in the older tests of the file.
- [ ] **Step 3: Rename in the project file.** Apply with a throwaway script that reads `project.pbxproj` as UTF-8, asserts each count, replaces, writes (the same replacements were run on a scratch copy and Xcode built it):

  | Old text | New text | Count |
  |---|---|---|
  | `name = Debug;` | `name = "Debug-Staging";` | 4 |
  | `name = Release;` | `name = "Release-Production";` | 4 |
  | `/* Debug */` | `/* Debug-Staging */` | 8 |
  | `/* Release */` | `/* Release-Production */` | 8 |
  | `defaultConfigurationName = Release;` | `defaultConfigurationName = "Release-Production";` | 4 |
  | `\"Release\"` (inside the three `shellScript` strings) | `\"Release-Production\"` | 3 |
  | `# ข้ามตอน Release/archive` | `# ข้ามตอน Production/archive` | 1 |
  | `Skipped for Release/archive like the lint phase.` | `Skipped for Production/archive like the lint phase.` | 1 |
  | `# Release only: the app being built must carry production's URL and no second copy of it (Scripts/check-release-config.sh). A Debug build skips this.` | `# Production only: the app being built must carry production's URL and no second copy of it (Scripts/check-release-config.sh). A Staging build skips this.` | 1 |

  Then `plutil -lint $REPO/Marauders-ios/Marauders.xcodeproj/project.pbxproj` — Expected: `OK`.
- [ ] **Step 4: Schemes.** In `xcshareddata/xcschemes/`: `mv Marauders.xcscheme "Marauders Staging.xcscheme"`; in it replace `buildConfiguration = "Debug"` (3 times: Test, Launch, Analyze) with `"Debug-Staging"` and `buildConfiguration = "Release"` (2 times: Profile, Archive) with `"Release-Production"`. Create `Marauders Production.xcscheme` as a copy of the result with these differences: every `buildConfiguration` is `"Release-Production"`; the build entry has `buildForTesting = "NO"`; the `TestAction` has `shouldUseLaunchSchemeArgsEnv = "YES"`, an empty `<Testables>` (no `TestableReference`) and no `<CommandLineArguments>`. In `xcuserdata/tiscomacnb2486.xcuserdatad/xcschemes/xcschememanagement.plist` replace the key `Marauders.xcscheme_^#shared#^_` by `Marauders Staging.xcscheme_^#shared#^_` (`orderHint` 0) and add `Marauders Production.xcscheme_^#shared#^_` with `orderHint` 1; keep the file's tab indentation; then `xmllint --noout` on both schemes and `plutil -lint` on the plist — Expected: no output from `xmllint`, `OK` from `plutil`.
- [ ] **Step 5: Run the test again.** `cd $REPO/backend && node --test test/scripts/iosEnvironments.test.mjs` — Expected: every test of the file passes (the 7 old tests and the 6 new ones, 13 in all, 0 failed).
- [ ] **Step 6: Prove it in real builds** (sync the mirror first; one `xcodebuild` at a time, logs to files). (a) `xcodebuild -list -project "$P"` — Expected: build configurations `Debug-Staging` and `Release-Production`, schemes `Marauders Production` and `Marauders Staging`, and `If no build configuration is specified and -scheme is not passed then "Release-Production" is used.` (b) `xcodebuild build -scheme "Marauders Staging"` (no `-configuration`) — Expected: `** BUILD SUCCEEDED **` and a log line `Building project Marauders with scheme Marauders Staging and configuration Debug-Staging`. (c) The same with `-scheme "Marauders Production"` — Expected: `** BUILD SUCCEEDED **`, `…with scheme Marauders Production and configuration Release-Production`, and the line `release config ok: https://marauders-api.js6ctz7gtj.workers.dev`. If `build` picks another configuration than the scheme's Run action, pass `-configuration` explicitly and ledger that. Ledger the three results.
- [ ] **Step 7: Checkpoint.**

---

### Task 2: Production carries no Debug-only type

**Files:**
- Modify: `Marauders-ios/Scripts/check-release-config.sh`, `Marauders-ios/Marauders.xcodeproj/project.pbxproj` (the guard phase), `Marauders-ios/Marauders/Presentation/Debug/DebugLogView.swift`, `Marauders-ios/Marauders/Presentation/Debug/CopyableStatusBanner.swift`
- Test: `Marauders-ios/Scripts/tests/check-release-config-tests.sh`, `backend/test/scripts/iosEnvironments.test.mjs`

**Interfaces:**
- Consumes: the phase `Run Script release config check` (id `7C3E91A0D5B44F28A1E6C0D9`), keyed on `Release-Production` by Task 1.
- Produces: `sh Scripts/check-release-config.sh --info-plist <Info.plist> --environments <environments.json> --bundle <Marauders.app> --executable <the app's executable>`, all four required; the variable `DEBUG_ONLY_TYPES="DebugLogView DevAuthAPIClient"` (space-separated type names, set at the top of the script); for each name found in the executable, `error: the executable <path> contains <Type>, a Debug-only type: a Production build must carry neither the in-app log nor the dev login`; a missing executable is `error: the executable <path> does not exist`. The success line `release config ok: <url>` and the exit codes (0 or 1) are unchanged. The Swift change: `DebugLogView` and the banner's View Log button exist only under `#if DEBUG`.

- [ ] **Step 1: Write the failing guard tests** in `check-release-config-tests.sh`. In `begin`, after the bundle exists, add `EXECUTABLE="$BUNDLE/Marauders"` and write a fixture executable that holds the neighbours of the names but not the names: `printf '\000\001some bytes AppLogStore CopyableStatusBanner DebugLog LogView\377\000\n' >"$EXECUTABLE"`. `run` passes `--executable "$EXECUTABLE"` as well. The existing case `fails when the bundle does not exist` must remove the folder with `rm -rf "$BUNDLE"` (the fixture executable keeps `rmdir` from working). Add these cases before the final summary (the 16 existing ones stay, so the run ends with 23):

```sh
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
```

- [ ] **Step 2: Run to verify it fails.** `sh $REPO/Marauders-ios/Scripts/tests/check-release-config-tests.sh` — Expected: FAIL with `unknown argument: --executable` in the output of nearly every case, and a non-zero exit.
- [ ] **Step 3: Implement the executable check in `check-release-config.sh`.** Add `--executable` to the option loop, its usage text and the required-argument checks (after `--bundle`, so the existing missing-argument cases still report `--bundle` first). Set `DEBUG_ONLY_TYPES="DebugLogView DevAuthAPIClient"` at column 0 under a comment saying these types exist only in DEBUG builds and must stay declared in the Swift sources (`iosEnvironments.test.mjs` checks that). After the bundle check: if `"$executable"` is not a file, `problem "the executable $executable does not exist"`; otherwise for each type, `LC_ALL=C grep -aq -- "$type" "$executable"` succeeding means the error line of the Interfaces block (a `problem`, so every problem is reported). Reword the header comment and the Release-URL error text from "Release build" to "Production build"; keep `release config ok:`.
- [ ] **Step 4: Run** `sh $REPO/Marauders-ios/Scripts/tests/check-release-config-tests.sh` — Expected: `check-release-config: all 23 cases passed`.
- [ ] **Step 5: Write the two source tests** in `iosEnvironments.test.mjs` (add `GUARD_SCRIPT = path.join(IOS_DIR, "Scripts", "check-release-config.sh")`):

```js
/** The text of every `.swift` file of the app and of the local packages (build folders left out). */
function swiftSources() {
  return ["Marauders", "Packages"].flatMap((folder) =>
    readdirSync(path.join(IOS_DIR, folder), { recursive: true })
      .filter((file) => file.endsWith(".swift") && !file.split("/").includes(".build"))
      .map((file) => readFileSync(path.join(IOS_DIR, folder, file), "utf8")),
  );
}

test("every Debug-only type the Production guard looks for is still declared in the Swift sources", () => {
  const types = /^DEBUG_ONLY_TYPES="([^"]+)"$/m.exec(readFileSync(GUARD_SCRIPT, "utf8"))?.[1]?.split(" ");
  assert.ok(types && types.length >= 2, "the guard must name its Debug-only types in DEBUG_ONLY_TYPES");
  const sources = swiftSources();
  for (const type of types) {
    const declared = new RegExp(`\\b(?:struct|class|enum|actor|protocol)\\s+${type}\\b`);
    assert.ok(sources.some((source) => declared.test(source)), `${type} is declared nowhere: the guard would look for nothing`);
  }
});

test("the guard's Run Script phase hands it the built executable and waits for that file", () => {
  const phase = /\/\* Run Script release config check \*\/ = \{([\s\S]*?)\n\t\t\};/.exec(readFileSync(PBXPROJ, "utf8"))?.[1] ?? "";
  assert.match(phase, /--executable \\"\$TARGET_BUILD_DIR\/\$EXECUTABLE_PATH\\"/);
  assert.match(phase, /"\$\(TARGET_BUILD_DIR\)\/\$\(EXECUTABLE_PATH\)",/);
});
```

- [ ] **Step 6: Run** `cd $REPO/backend && node --test test/scripts/iosEnvironments.test.mjs` — Expected: the needle test passes at once (the types exist, so this one gets its RED from a mutation, next step) and the wiring test FAILS (the phase has no `--executable` yet).
- [ ] **Step 7: Mutation check of the needle test.** Change `DebugLogView` to `DebugLogViewX` in `DEBUG_ONLY_TYPES`, run the file — Expected: the needle test fails with `DebugLogViewX is declared nowhere`; restore the name and run again — Expected: it passes.
- [ ] **Step 8: Wire the phase** in `project.pbxproj`: the phase's `inputPaths` gets a second entry `"$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)",` after the Info.plist one; its script's comment becomes `# Production only: the app being built must carry production's URL, no second copy of it and no Debug-only type (Scripts/check-release-config.sh). A Staging build skips this.`; its command line gets ` --executable \"$TARGET_BUILD_DIR/$EXECUTABLE_PATH\"` after the `--bundle` argument. `plutil -lint` the project file — Expected: `OK`. Run the file's tests — Expected: all pass.
- [ ] **Step 9: See the guard fail on today's Swift (RED for the Swift change).** Sync the mirror, then `xcodebuild build -project "$P" -scheme "Marauders Production" -destination "$DEST" …` — Expected: `** BUILD FAILED **` with `error: the executable …/Marauders.app/Marauders contains DebugLogView, a Debug-only type: …` and no line naming `DevAuthAPIClient`.
- [ ] **Step 10: Gate the in-app log in Swift.** In `DebugLogView.swift` keep the imports, put this comment above the new `#if DEBUG`: `// The in-app log is a Staging feature (the DEBUG flag). A Production build does not contain this type, and the guard Scripts/check-release-config.sh fails a build that does.`, and wrap the `struct` and the `#Preview` in `#if DEBUG` … `#endif`. In `CopyableStatusBanner.swift` change `viewLogLink` to:

```swift
    @ViewBuilder
    private var viewLogLink: some View {
        #if DEBUG
            NavigationLink {
                DebugLogView()
            } label: {
                Label("View Log", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
        #endif
    }
```

  Then `cd $REPO/Marauders-ios && xcrun swift-format lint Marauders/Presentation/Debug/DebugLogView.swift Marauders/Presentation/Debug/CopyableStatusBanner.swift` — Expected: no output (if it reports indentation, `xcrun swift-format format -i` the two files and lint again).
- [ ] **Step 11: See it pass (GREEN).** Sync the mirror; the built app is `$SCRATCH/DerivedData/Build/Products/<configuration>-iphonesimulator/Marauders.app` (`<configuration>` is `Release-Production` or `Debug-Staging`), and the log of (a) is kept in a file for Task 4. (a) `xcodebuild build … -scheme "Marauders Production"` — Expected: `** BUILD SUCCEEDED **`, `release config ok: https://marauders-api.js6ctz7gtj.workers.dev`, and `LC_ALL=C grep -ac DebugLogView <built app>/Marauders` prints `0`. (b) `xcodebuild build … -scheme "Marauders Staging"` — Expected: `** BUILD SUCCEEDED **`, and `LC_ALL=C grep -ac DebugLogView <built app>/Marauders.debug.dylib` prints a number above 0 (the log screen is still compiled into Staging). (c) `python3 $REPO/Marauders-ios/Scripts/find-plain-strings.py` and `sh $REPO/Marauders-ios/Scripts/check-layers.sh --strict` — Expected: `OK: no plain strings` and exit 0.
- [ ] **Step 12: Mutation checks in real builds** (mirror only, restore afterwards). (a) Build `Marauders Production` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG'` added to the command line — Expected: `BUILD FAILED` and the guard names `DebugLogView`, and `DevAuthAPIClient` too if the override reaches the package. If the build stops earlier (a compile error) or the override does not reach the package, ledger that: the `DevAuthAPIClient` needle then rests on its shell case. (b) If `xcodebuild analyze -scheme "Marauders Production"` fails in the guard because the executable is missing, rule it (ledger): add `if [ "$ACTION" = "analyze" ]; then exit 0; fi` to the phase script, with a case in the phase-wiring test; if it passes, nothing changes.
- [ ] **Step 13: Checkpoint.**

---

### Task 3: CI, test comments and docs follow the new names

**Files:** `Marauders-ios/fastlane/Fastfile`, `Jenkinsfile`, the four Swift files whose comments name the old scheme or the Log tab (file map), `README.md`, `ARCHITECTURE.md`, `docs/ci-cd.md`, `deployment/README.md`, `docs/adr/010-environments.md`; Create/Test: `backend/test/scripts/noRetiredBuildNames.test.mjs`.

**Interfaces:**
- Consumes: the names of Global Constraints and the guard's behaviour of Task 2.
- Produces: no command in the written-down places names `-scheme Marauders`, `-configuration Debug` or `-configuration Release`.

- [ ] **Step 1: Write the failing test** `backend/test/scripts/noRetiredBuildNames.test.mjs`: a header comment saying what it guards (see the spec), imports `assert`, `existsSync`, `readdirSync`, `readFileSync`, `statSync`, `path`, `test` and `BACKEND_DIR` from `../../scripts/lib/targets.mjs`, `REPO = path.resolve(BACKEND_DIR, "..")`, and:

```js
const PLACES = [
  "README.md", "ARCHITECTURE.md", "Jenkinsfile", "docs/ci-cd.md", "deployment", ".github",
  "Marauders-ios/fastlane", "Marauders-ios/Scripts", "Marauders-ios/MaraudersTests", "Marauders-ios/MaraudersUITests",
];
const TEXT_FILE = /\.(md|mjs|js|json|ya?ml|sh|rb|swift|py|txt|toml)$|(^|\/)(Jenkinsfile|Fastfile)$/;
const SKIPPED_FOLDERS = new Set(["node_modules", ".build", "build", "vendor", ".git"]);
const RETIRED = [
  { what: 'the scheme "Marauders"', pattern: /-scheme\s+(?:"Marauders"|'Marauders'|Marauders(?![\w.-]))/ },
  { what: 'the configuration "Debug" or "Release"', pattern: /-configuration\s+(?:"(?:Debug|Release)"|'(?:Debug|Release)'|(?:Debug|Release)(?![\w.-]))/ },
  { what: 'a gym configuration "Debug" or "Release"', pattern: /\bconfiguration:\s*["'](?:Debug|Release)["']/ },
];

/** Yields the repo-relative path of every file under `entry` (a file or a folder; a missing entry yields nothing) that TEXT_FILE accepts, skipping SKIPPED_FOLDERS. */
function* textFiles(entry) {
  /* recurse with readdirSync and statSync */
}

function retiredNames(line) {
  return RETIRED.filter(({ pattern }) => pattern.test(line)).map(({ what }) => what);
}

test("the scan flags the retired names and accepts the new ones", () => {
  for (const line of [
    "xcodebuild test -scheme Marauders -destination x", "(`xcodebuild test -scheme Marauders`)", '-scheme "Marauders"',
    "-scheme Marauders \\", "-scheme Marauders Staging", "-configuration Release -destination x", '-configuration "Debug"',
    'gym(configuration: "Release")',
  ]) {
    assert.notEqual(retiredNames(line).length, 0, line);
  }
  for (const line of [
    '-scheme "Marauders Staging"', "-scheme 'Marauders Production'", '"-scheme #{TEST_SCHEME}"', "-configuration Release-Production",
    '-configuration "Debug-Staging"', "configuration: RELEASE_CONFIGURATION", "-only-testing:MaraudersTests", "-project Marauders.xcodeproj",
  ]) {
    assert.deepEqual(retiredNames(line), [], line);
  }
});

test("no written-down command names a retired scheme or configuration", () => {
  const violations = [];
  for (const place of PLACES) {
    for (const file of textFiles(place)) {
      readFileSync(path.join(REPO, file), "utf8").split("\n").forEach((line, index) => {
        for (const what of retiredNames(line)) violations.push(`${file}:${index + 1}: ${what}: ${line.trim().slice(0, 100)}`);
      });
    }
  }
  assert.deepEqual(violations, []);
});
```

- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/noRetiredBuildNames.test.mjs` — Expected: the pattern test passes, the scan test FAILS listing at least `README.md` (the unit-test command), `ARCHITECTURE.md` (the run-tests line), `Jenkinsfile` (`-scheme Marauders`), `Marauders-ios/MaraudersTests/LanguageDetectionDeviceTests.swift` (its comment) and `Marauders-ios/fastlane/Fastfile` (`configuration: "Release"`).
- [ ] **Step 3: CI and comments.** `Fastfile`: replace `SCHEME` by `PROJECT_NAME = "Marauders"` (the `.xcodeproj` and the ipa name), `TEST_SCHEME = "Marauders Staging"`, `RELEASE_SCHEME = "Marauders Production"`, `RELEASE_CONFIGURATION = "Release-Production"`; the `test` lane passes `"-scheme '#{TEST_SCHEME}'"`; `gym` gets `project: File.join(PROJECT_ROOT, "#{PROJECT_NAME}.xcodeproj")`, `scheme: RELEASE_SCHEME`, `configuration: RELEASE_CONFIGURATION`, `output_name: "#{PROJECT_NAME}.ipa"`; the two `desc` lines say Production instead of Release. `Jenkinsfile`: the package-resolve step takes `-scheme "Marauders Production"`. Comments: `LanguageDetectionDeviceTests.swift` line 12 uses `-scheme "Marauders Staging"`; the Log-tab comments in `MaraudersThaiUITests.swift` (about line 119), `MaraudersAccessibilityUITests.swift` (about 387) and `MaraudersUITests.swift` (about 1234) say "a Staging build" instead of "a Debug build". Then `ruby -c $REPO/Marauders-ios/fastlane/Fastfile` — Expected: `Syntax OK`.
- [ ] **Step 4: Docs.** Facts every file must end up stating, in its own language and style (leave the compiler-flag wording alone):
  - `README.md` (Thai): a new short section after the iOS run steps, "Staging และ Production", with a table of Scheme / Configuration / when it is used / in-app log (the Log tab and the upload banner's View Log) / Simulator dev login, URL override and session-fault argument / Worker (production for both for now) / Release guard (skipped, runs); one sentence that the debug side's name must start with "Debug" so the local package gets `DEBUG`; the unit-test command becomes `xcodebuild test -scheme "Marauders Staging" -only-testing:MaraudersTests -destination …`; the lines that call the Debug or Release build an environment (the table row for the log, the folder tree comments for `Config/` and `Scripts/`, the environments paragraph, the run steps, the tab list, the troubleshooting rows) say Staging or Production; the roadmap line "ซ่อนแท็บ Log ใน Release build" also names the View Log button.
  - `ARCHITECTURE.md` (English): the box line about the log (keep the border aligned) says the in-app log is for Staging builds only; the *Environments* section gets a bullet "Two builds of the app" (the table of Global Constraints in prose, the `Debug` name rule, same bundle id and why: one `APPLE_CLIENT_ID` on the Worker), and its guard bullet says what the guard now also checks (the executable holds neither `DebugLogView` nor `DevAuthAPIClient`); the lines about which build talks to which Worker or reads which vars file, the strings-sync recipe (a sync runs from a **Staging** build; the build-folder path becomes `Debug-Staging-iphonesimulator`), the test-language line (the `Marauders Staging` scheme's Test action), the layer-check line (Staging builds only), the `Presentation/Debug/` line (the log screen and the banner's View Log button are `#if DEBUG`), the run-tests command (`-scheme "Marauders Staging"`) and the launch-argument paragraph (a Staging build) follow.
  - `docs/ci-cd.md` (Thai): the scheme row lists both scheme files; the lane description says `Marauders Production` and `Release-Production`; the "scheme not found" troubleshooting names both files; the guard paragraph says Production and the executable check.
  - `deployment/README.md` (Thai): the table of build settings per configuration is `Debug-Staging` (Staging) and `Release-Production` (Production); the lines about pointing Debug at staging, the Log tab host caption, the dev login and the guard say Staging or Production and name `Debug-Staging` where they name the build setting.
  - `docs/adr/010-environments.md` (English): Scope also names the schemes and the guard; a second amendment, dated 2026-11-20 (later), with the decision (names and the rule behind them, the two schemes, the in-app log and the guard's check, same bundle id), its consequences (TestFlight loses View Log; commands outside the repository need the new names; the first build is a full rebuild) and the two alternatives (keep `Debug`/`Release` and only add schemes; four configurations), linking the design.
- [ ] **Step 5: Run** `cd $REPO/backend && node --test test/scripts/noRetiredBuildNames.test.mjs` — Expected: both tests pass. Then the sweeps (each hit must be the compiler flag or deliberate history; list the survivors in the ledger): `cd $REPO && grep -nE "Debug build|Release build|Debug-only|DEBUG build|build Debug|Marauders\.xcscheme|'Marauders'" README.md ARCHITECTURE.md docs/ci-cd.md deployment/README.md`.
- [ ] **Step 6: Checkpoint.**

---

### Task 4: Gate

**Files:** none (verification, review, memory).

- [ ] **Step 1: Backend.** `cd $REPO/backend && npm test` — Expected: exit 0, typecheck clean, `test:scripts` 116 tests (106 + 8 new in `iosEnvironments.test.mjs` + 2 in the new file), every route suite green. Read the counts; a different number needs an explanation in the ledger.
- [ ] **Step 2: Script suites.** `sh $REPO/Marauders-ios/Scripts/tests/check-release-config-tests.sh` (23 cases), `…/check-layers-tests.sh` (31), `…/find-plain-strings-tests.sh` (33); `sh $REPO/Marauders-ios/Scripts/check-layers.sh --strict` (exit 0); `python3 $REPO/Marauders-ios/Scripts/find-plain-strings.py` (`OK: no plain strings`).
- [ ] **Step 3: Unit target under Staging** (mirror synced): `xcodebuild test … -scheme "Marauders Staging" -only-testing:MaraudersTests` — Expected: `** TEST SUCCEEDED **`, `Test run with 1347 tests in 134 suites` all passed.- [ ] **Step 4: UI target under Staging**, in the background, from a freshly synced mirror: `-only-testing:MaraudersUITests`. Expected (about 21 minutes): 79 executed, 78 passed, exactly one failure, the known simulator-only `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn`, and exit 65 because of it. Any other failure is a finding.
- [ ] **Step 5: Production proofs** (one `xcodebuild` at a time, unsigned, `DerivedData-release` of its own): (a) `xcodebuild analyze … -scheme "Marauders Production" -destination "$DEST"` — Expected: `** ANALYZE SUCCEEDED **` (or the Task 2 step 12 ruling). (b) `xcodebuild archive -project "$P" -scheme "Marauders Production" -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/DerivedData-release" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" -archivePath "$SCRATCH/Marauders.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` — Expected: `** ARCHIVE SUCCEEDED **`, the line `release config ok: https://marauders-api.js6ctz7gtj.workers.dev`, and `LC_ALL=C grep -ac DebugLogView "$SCRATCH/Marauders.xcarchive/Products/Applications/Marauders.app/Marauders"` prints `0` (the same for `DevAuthAPIClient`). (c) The same archive with `MARAUDERS_API_BASE_URL=https://marauders-api-staging.js6ctz7gtj.workers.dev` added to the command line — Expected: exit 65 and an `error: ` line from the guard. (d) The Production simulator build log kept in Task 2 step 11 has no `-D DEBUG` on any compile line of the three modules: `grep -E -- '-module-name (Marauders|MaraudersAuth|MaraudersAuthData) ' "$LOG" | grep -cE -- '(^| )-D ?DEBUG( |$)'` — Expected: `0`.
- [ ] **Step 6: Whole-diff review.** Build `$WORK/review.diff`: for every file under `$WORK/base`, `diff -u "$WORK/base/<path>" "$REPO/<path>"` (the scheme: base `Marauders.xcscheme` against the new `Marauders Staging.xcscheme`), and `diff -u /dev/null` for the files this plan created. Dispatch one fresh reviewer on the most capable model with the diff, this plan, the spec, the ledger's `Ruling:` lines and the Review Focus verbatim. Re-grade its findings by effect; Critical and Important get one fix pass, each with a failing test first and a green suite after; minors go to the ledger as `Final: minor (deferred): …`.
- [ ] **Step 7: Commit groups on prospective trees.** The three groups of the environments rework change as follows: group 2 (`Marauders-ios/**` except `RetryingHTTPClient.swift`, plus `backend/test/scripts/iosEnvironments.test.mjs`) now holds this plan's app work; group 3 (`.github/**`, `backend/test/scripts/workflow.test.mjs`, the docs) also takes `Jenkinsfile` and `backend/test/scripts/noRetiredBuildNames.test.mjs` (that test reads the docs, so it cannot stand in group 2). Adapt the previous session's `prospective.sh` (read `git status --porcelain -z`: two scheme paths contain a space; add the `Jenkinsfile` and `noRetiredBuildNames` rules), run it for K = 1, 2, 3 — Expected: `npm test` exit 0 for each tree.
- [ ] **Step 8: Ledger and memory.** Append the evidence and every `Ruling:` to the ledger; update the memory notes (`project-environments-assessment.md`, `project-environments-rulings-and-minors.md`, the index, and the test recipes in `feedback-run-tests-on-simulator.md` to `-scheme "Marauders Staging"`); list every ruling and every deferred minor in the closing message; delete `$WORK` only when the final review is clean and its rulings have a durable copy in memory.
- [ ] **Step 9: Checkpoint.**

---

## Commit grouping (run only on the owner's order, all three before the production deploy of the environments rollout; each message ends with the `Co-Authored-By` trailer the session was given)

1. `Give the backend a staging environment and scripts that name their target`: `backend/**` except the three test files named below, plus `.gitignore`.
2. `Give the app Staging and Production builds on the one backend, and fail a Production build that carries a debug aid`: `Marauders-ios/**` except `RetryingHTTPClient.swift`, plus `backend/test/scripts/iosEnvironments.test.mjs`.
3. `Run the backend tests on GitHub and write the environments down`: `.github/**`, `backend/test/scripts/workflow.test.mjs`, `backend/test/scripts/noRetiredBuildNames.test.mjs`, `Jenkinsfile`, `README.md`, `ARCHITECTURE.md`, `deployment/**`, `docs/ci-cd.md`, `docs/adr/**`.

Never stage the owner's `RetryingHTTPClient.swift` or the untracked session-core docs; this plan and its design are committed in commit 3 only if the owner says so. Stage by explicit path (the two scheme paths contain a space, so quote them).
