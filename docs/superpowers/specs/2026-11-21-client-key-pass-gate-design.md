# The app runs only with the pass: a gate on `MARAUDERS_CLIENT_KEY`

Date: 2026-11-21. Status: **approved by the owner on 2026-11-21 ("อนุมัติ A"), as proposed in chat.** Size: a small change (one rule, one gate, one screen with two Thai strings, the project value, tests, docs). It amends `2026-11-21-injected-build-value-design.md`, which is built and uncommitted.

## Intent and why

The owner, after running the app from Xcode with the mock value: `MARAUDERS_CLIENT_KEY ต้องเป็น "run by pass" เท่านั้น แอปถึงจะ run ได้` ("the key must be `run by pass` only; only then can the app run"). Just before that they had asked what must come out of the project to test, and were told nothing: the wrong answer to this, because the app ran with any value. Nothing checked it.

Reading, confirmed by "อนุมัติ A": the app runs only when `MARAUDERS_CLIENT_KEY` is exactly `run by pass`. Surrounding whitespace is ignored; case and spaces are as typed. Any other text, a blank or a missing value means the app does not run.

The reason behind it was not stated. My reading, for the owner to correct: make the value matter, so that "Jenkins injects it" can be shown. With no pass in the project, a build runs only if Jenkins supplied the pass. The flow the owner first described stays: during testing the project holds the pass so the app runs from Xcode; to prove Jenkins's, the two project lines come out (or hold another text) and a Run shows the block screen.

The pass is in git (the repository is public) and in the app. This is a simulated gate that shows the value arrived. It protects nothing.

## What changes in the approved design

- The non-goal "sending the value anywhere or checking it" loses its second half: the app checks the value against the pass. Nothing sends it anywhere and there is no Worker change.
- The anti-goal "a build-time failure on a scheme the owner runs from Xcode" stands and decides the approach: the gate is at run time, so every build still builds.
- The mock default `mock-client-key-local-only` becomes the pass. The script test that pinned a `mock-` prefix pins the pass instead.
- The Jenkins credential `marauders-client-key` must hold exactly `run by pass`. `docs/ci-cd.md` said "a made-up value such as `openssl rand -hex 16`", which would now make every TestFlight build refuse to run.

## Goals

1. A build carrying the pass runs exactly as it does today.
2. A build carrying anything else opens one screen that says it cannot run and starts nothing: no Keychain session check, no background location, no upload session, no network.
3. A plain Run from Xcode (Staging or Production scheme), the unit tests, the UI tests and an unsigned archive still work with no setup, because the project holds the pass.
4. The owner can show that Jenkins supplies the pass: with the project lines removed, a Run blocks, and a Jenkins build with the credential runs.

## Non-goals

A check on a server. A build-time guard or a Run Script phase. A Debug environment-variable override of the value. A check in the Jenkins lane before upload (offered as an add-on, not chosen). Making the pass a secret. Changing the Staging Log caption (`client key: set|missing`, which a blocked app never reaches).

## Anti-goals

Failures that would count even if every test passed:

- A build that fails on a scheme the owner runs from Xcode.
- The pass or any other value in a log, a screenshot or on the block screen. The screen must not hint at the pass.
- Anything starting before the check: a blocked app that still resumes location sharing, opens the upload session or reads the Keychain.

## Constraints

Swift 6.4, Xcode 27.2, iOS 27.0, swift-format at 120 columns. The layer rules and `Scripts/find-plain-strings.py` still pass: every user-facing text is localized, with a Thai text in `Localizable.xcstrings`. Tests run on the iOS 27.2 simulator.

## Approaches

- **A. A run-time gate in the app. Chosen.** The app checks the pass before it starts anything and otherwise shows a block screen. Every build still builds, so a plain Run from Xcode cannot fail at the build. Cost: a build with a wrong value can still reach TestFlight if Jenkins is mis-set, and shows the block screen only when opened.
- B. A build-time failure: a Run Script phase compares the setting and Xcode or Jenkins stops. Clearer, and it keeps a bad build off TestFlight, but it is the guard that stopped the owner's Run of the Production scheme on 2026-11-21 and the approved design's anti-goal. Not chosen.
- C. An add-on to A, not chosen unless asked: the Jenkins lane stops before upload when the injected value is not the pass (three lines in the Fastfile; it never runs in Xcode). It would keep a build that cannot open off TestFlight.

## Design

**Rule** (`Shared/Configuration/ClientKey.swift`): the one accepted value is the constant `ClientKey.pass`, `run by pass`. A function with no bundle says whether a configured text is the pass (`resolve(configured:)` first, so trimming, blank, `$(` and control characters behave as today, then an exact comparison), and one reads the Info.plist key of this build.

**Gate** (`App/MaraudersApp.swift`): at the top of `init()`, before the session guard, the background location monitor and the upload session, a build that is not the pass logs one line (never the value) and returns. In `body` the window shows `AppRootView()` for the pass and the block screen otherwise. The `.backgroundTask(.urlSession …)` closure returns at once when blocked.

**Block screen** (`Presentation/Splash/`): one centred symbol, a title and one sentence, localized, with Thai. It says the build has no valid client key and never shows the value or the pass.

**Project, Jenkins, docs:** the two build settings become `run by pass`. The Fastfile line is unchanged: `Shellwords.escape` already handles spaces, and the earlier archive runs covered spaces and quotes. `docs/ci-cd.md` gives the credential its exact value, tells how to test the injection (remove the two project lines: a Run blocks, a Jenkins build runs) and drops the advice that suited a random value. `README.md`, `ARCHITECTURE.md` and `deployment/README.md` get the same fact in a sentence each.

## Proof owed

- Swift Testing: the pass is accepted, also with surrounding whitespace; other text, a different case, extra words, blank, missing, an unexpanded `$(…)` and a control character are not; the built app carries the pass.
- Script tests (`cd backend && npm test`): both app configurations hold exactly the pass; `MaraudersApp.swift` checks the pass before anything starts and shows `AppRootView()` only for it; `docs/ci-cd.md` names the credential's exact value.
- Real builds on the iOS 27.2 simulator: with the pass the app runs; built with a wrong value on the xcodebuild line it shows the block screen, and the log has no `upload.bg launch` line (nothing started). An unsigned Production archive reads back the pass, also when given the Fastfile's escaped argument.
- Not provable without the owner: the Jenkinsfile binding (a push and a Build Now come first), and the Thai wording, which the owner reviews.

## Left to the builder

Names, the symbol, the exact title and sentence and their Thai, test names, the wording of the docs.

## My calls

For the owner to check:

1. Exact match after trimming, case-sensitive, spaces as typed.
2. The block screen never shows or hints at the pass.
3. No Debug environment-variable override (the earlier ruling stands), so nothing can fake a wrong value inside a test. The wiring is pinned by a script test and shown by one real run with a wrong value.
4. The `.backgroundTask` closure is guarded as well, so a relaunch by the system cannot start the uploader.
5. The decision is read from the bundle each time, not cached: it costs one dictionary lookup.
6. The Staging Log caption stays as it is.
