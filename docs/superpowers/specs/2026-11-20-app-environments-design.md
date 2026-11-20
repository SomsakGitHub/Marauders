# App environments: Staging and Production builds

Date: 2026-11-20. Status: **approved by the owner on 2026-11-20 ("อนุมัติ"); nothing is built yet.** It builds on the uncommitted one-backend rework (ADR-010, amended 2026-11-20). Size: a small change (the project file, two schemes, two Swift files, one script, tests, CI names, docs; no new dependency).

## Intent and why

The owner said the front end has a staging and a production, both on the one production backend (`หน้าบ้านมี staging และ prod เชื่อมต่อกับหลังบ้าน prod ตัวเดียว`), asked for them to be separated by **build configuration and scheme** (`Environments: Staging / Production แยกด้วย build configuration และ scheme แต่ใช้ backend production เหมือนกันหมด`), and said what should differ: `Staging ต่างจาก Production ตรง log ในแอป ใช้ตอน run`.

So the app gets two named environments. **Staging is the build you run from Xcode and it has the in-app log; Production is what TestFlight and the App Store ship and it has no in-app log.** The reason: the owner can tell from the scheme in the toolbar which one is running, and the build that ships cannot carry debugging aids.

## What exists today

Found by reading the project and by three throwaway builds on a scratch copy (nothing in the repository was touched):

- Two build configurations, `Debug` and `Release`, each in four configuration lists (project, app, `MaraudersTests`, `MaraudersUITests`), and one shared scheme `Marauders` (Run, Test and Analyze use Debug; Profile and Archive use Release). Both configurations already build for the production URL.
- `#if DEBUG` is the switch for every Debug aid: the Log tab, the Simulator's dev login, the launch-environment URL override, session-fault injection and more.
- **Production is not log-free today.** The upload status banner's **View Log** button opens the log screen in every build, so a TestFlight build has an in-app log. ARCHITECTURE.md says the log is DEBUG-only and the README roadmap ticks "hide the Log tab in Release builds"; the button was missed.
- **The name of a configuration decides whether the local package `MaraudersAuth` gets the `DEBUG` flag.** On the scratch copy a configuration named just `Staging` built the app with `DEBUG` and the package modules without it, and the build failed (`DevAuthAPIClient` not found). `Debug-Staging` and `Staging-Debug` both built, with `DEBUG` in the app and in both package modules, so a name with "Debug" in it gets the flag and a name without it does not.
- `Release-Production` built for the simulator with no `DEBUG` in any of the three modules, and the Release guard ran and passed under the new name. Its executable contains the log screen (`DebugLogView`) and none of the dev-login types (`DevAuthAPIClient`, `SignInAsDevUserUseCase`, `DebugSessionFault`).

## Goals

1. Two build configurations and two shared schemes named after the environments, so the toolbar shows which one runs.
2. Staging keeps the in-app log and every Debug aid it has today. Production has none of them, including the **View Log** button.
3. Both build for the production backend, one build setting each, with a comment where to change Staging's when a staging backend exists.
4. Everything that names the old scheme or the old configurations follows: the CI lane, the Jenkinsfile, the guard, the tests, the docs.

## Non-goals and anti-goal

- A second bundle id, name or icon for Staging. The Worker checks Sign in with Apple against one `APPLE_CLIENT_ID`, so a different bundle id would break sign-in until the Worker accepts two. Staging and Production replace each other on one phone, as Debug and TestFlight do today.
- A staging backend (it stays dormant, ADR-010), a `Release-Staging` or `Debug-Production` configuration, and any move of `#if DEBUG` code other than the log button and the log screen.
- Stopping `AppLogStore` from recording in Production. It feeds the system log and the unit tests; only the screen goes.
- Anti-goal: a Production build that can open the log or offer the dev login.

## Approaches

1. **Rename the two configurations and split the scheme** (my pick; the owner handed me the how). `Debug` becomes `Debug-Staging`, `Release` becomes `Release-Production`, and there are two schemes. It does exactly what was asked, uses the usual naming, and the name rule above is satisfied.
2. **Keep `Debug` and `Release`, add two schemes.** Cheapest and nothing renames, but the build configurations are not separated by environment, which was asked for, and only the scheme name says which is which.
3. **Four configurations** (`Debug` and `Release`, each for Staging and for Production). The common template, but two configurations nothing uses, and sixteen build-setting blocks to keep in step instead of eight.

## Design

**Configurations.** Rename in place, in all four lists, so every setting, signing choice and the `DEBUG` condition stay as they are: `Debug` to `Debug-Staging`, `Release` to `Release-Production` (also the default configuration of each list). `MARAUDERS_API_BASE_URL` stays the production Worker in both.

**Schemes** (shared, in `xcshareddata/xcschemes/`). The old `Marauders` scheme goes away.

| Scheme | Run, Analyze | Test | Profile, Archive |
|---|---|---|---|
| `Marauders Staging` (the old scheme, renamed, test targets and English launch arguments kept) | `Debug-Staging` | `Debug-Staging` | `Release-Production` |
| `Marauders Production` (new, the app only, no test targets) | `Release-Production` | none | `Release-Production` |

Archiving from either scheme gives the Production build, so an archive cannot carry the log by accident.

**Run Script phases.** The three phases that key on the name `Release` key on `Release-Production`: the swift-format lint and the layer check skip it, the Release guard runs only for it.

**The in-app log.** `CopyableStatusBanner`'s View Log button and `DebugLogView` go inside `#if DEBUG`; in Production the banner shows **Copy Message** only. The Log tab is already DEBUG-only.

**The guard proves it.** The Release guard already inspects what would ship (the built Info.plist and bundle). It also fails the Production build when the built executable contains a Debug-only type: `DebugLogView` (the log) or `DevAuthAPIClient` (the dev login). So the rule "Production cannot carry debugging aids" cannot be undone by accident, and it is checked on the binary, not on the source. My call; it is one extra check, with its cases in the existing script tests.

**Tests.** `backend/test/scripts/iosEnvironments.test.mjs` follows the new names and also checks: the four lists carry exactly these two configurations; both build for production's URL; each scheme maps its actions as in the table; the Production scheme has no test targets; the three phases key on `Release-Production`; every type name the guard looks for is still declared in the Swift sources (so a rename cannot leave the guard checking nothing). The shell tests of the guard get the new cases. The unit and UI suites run unchanged under `Marauders Staging` on the simulator, from a scratch copy.

**CI and docs.** `fastlane` (`test` lane uses `Marauders Staging`, `build` lane uses `Marauders Production` and `Release-Production`; the project and ipa names stay `Marauders`), the Jenkinsfile package-resolve step, README, ARCHITECTURE (the environments section, the test command, the lines that call the log DEBUG-only, the strings-sync recipe that says "Debug build"), `docs/ci-cd.md`, `deployment/README.md`, and an amendment to ADR-010.

## What changes for the owner and for users

- Xcode's toolbar offers `Marauders Staging` and `Marauders Production` instead of `Marauders`. Staging shows the Log tab; Production does not.
- A failed upload's banner in TestFlight loses **View Log**. Device logs there come from the system log (Console, sysdiagnose), as for any release build.
- Any command, script or habit outside the repository that says `-scheme Marauders` or `-configuration Debug` needs the new names. The first build after the rename is a full rebuild (the build folders are named after the configurations).

## Proof the builder owes

Backend suite and shell tests green; the unit and UI suites green under `Marauders Staging` on the iOS 27.2 simulator; `Marauders Production` builds for the simulator with no `DEBUG` in any module, the guard passes, and the executable has no log type (the guard check is first seen failing on today's code, which still has it); `xcodebuild analyze` and an unsigned archive of `Marauders Production` pass the guard too; `Marauders Staging` still has the Log tab; a mutation (the log type back in Production) makes the guard fail.

## Left to the builder

The exact wording of the guard's new error line, the order of the doc edits, and whether the tracked `xcschememanagement.plist` entry is updated or left for Xcode to rewrite.
