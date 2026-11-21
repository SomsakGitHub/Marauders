# One build-time value: Jenkins injects it, a mock default lets Xcode run

Date: 2026-11-21. Status: **approved by the owner on 2026-11-21 ("อนุมัติ"), as proposed in chat.** Size: a small change (one build setting, one reader, one fastlane line, one Jenkinsfile line, docs).

> **Amended later on 2026-11-21:** the owner then required that the app run only when the value is exactly the pass `run by pass` (`MARAUDERS_CLIENT_KEY ต้องเป็น "run by pass" เท่านั้น แอปถึงจะ run ได้`). That reverses the non-goal "checking it", replaces the mock default and fixes the Jenkins credential's value: see `2026-11-21-client-key-pass-gate-design.md`. The rest of this design stands.

## Intent and why

The owner, under "CI/CD and Infrastructure": simulate one value in the front end (the iOS app); Jenkins injects it when it runs; during testing the same value goes into the app so it runs from Xcode first (`CI/CD และ Infrastructure ความตั้งใจคือ อยากจำลองค่าขึ้นมา 1 ค่าในหน้าบ้าน ให้ Jenkins inject ค่าให้ตอนรัน แต่ช่วงทดสอบก็สามารถเอาค่านั้นมาใส่หน้าบ้านเพื่อให้แอป run บน xcode ได้ก่อน`).

The reason behind it was not stated. My reading, for the owner to correct: have a working path for a build-time value from Jenkins into the app, and a plain Run from Xcode that never needs Jenkins, before any real value depends on it. This is the front-end half of the client secret the owner cancelled on 2026-11-21 (branch `worktree-client-secret`; see `2026-11-21-client-key-design.md`). It has no Worker half and does not revive that work.

An iOS app has no server environment at run time, so "Jenkins injects it" means: Jenkins hands the value to the build, and the build bakes it into the app's Info.plist.

## What exists today

Read on 2026-11-21:

- The model for a build-time value is `MARAUDERS_API_BASE_URL`: a user-defined build setting on the app target (both configurations), handed to Info.plist by `Marauders-ios/Config/Info-Additions.plist` as `$(NAME)` (Xcode ignores an unknown `INFOPLIST_KEY_` name, so this is the only way), read by `Shared/Configuration/APIBaseURL.swift`.
- The Jenkins job `Marauders-ios` is a pipeline from SCM (`git@github.com:SomsakGitHub/Marauders.git`, branch `*/main`, script `Jenkinsfile`), with no parameters and no triggers. Jenkins was running on :8080 that day. Its credentials are `asc-api-key`, `asc-key-id`, `asc-issuer-id` and `jfrog-sdk-swift-token`. The Deploy stage binds them and runs `bundle exec fastlane beta`; the lane `build` already passes `CURRENT_PROJECT_VERSION=$BUILD_NUMBER` to xcodebuild through `xcargs`. A build setting given on the xcodebuild command line overrides the project's.
- The Production guard (`Scripts/check-release-config.sh`) and `backend/test/scripts/iosEnvironments.test.mjs` pin only the URL setting; a second key breaks neither.
- Production has no in-app log by design (`DebugLogView` is `#if DEBUG`, and the guard fails a Production build that contains it).

## Goals

1. A build Jenkins makes carries the value Jenkins holds.
2. A plain Run from Xcode (the Staging or the Production scheme), the unit tests and an unsigned archive work with no setup: the project holds a mock default.
3. One small type reads the value; it never prints or logs it; Staging's log screen says only `set` or `missing`.

## Non-goals

Sending the value anywhere (the Worker included) or checking it; any Worker change or deploy; a build guard for it; a helper script; a different value per environment; making it a real secret.

## Anti-goals

Failures that would count even if every test passed:

- A build-time failure on a scheme the owner runs from Xcode (they hit one on 2026-11-21).
- A real secret in git (the repository is public).
- A TestFlight build that depends on more than one new Jenkins credential.
- The value in a log.

## Approaches

Laid out in the proposal the owner approved:

- **A. A mock default in the project; Jenkins overrides it through xcargs. Chosen.** It mirrors the URL setting, Xcode needs nothing, Jenkins needs one credential. Cost: the mock is public in git, and a build made outside Jenkins (an Archive from Xcode) carries the mock.
- B. A git-ignored xcconfig for the local value, the same xcargs in Jenkins. This is the upgrade path once the value is real (one place changes). It has more files, and a Run without the file has no value. Not now.
- C. A Run Script phase that fills the plist from a vars file, plus a Production guard on a missing value (the cancelled branch). The most machinery, and its guard stopped the owner's Run of the Production scheme. Not chosen.

## Design

**App**

- A build setting `MARAUDERS_CLIENT_KEY` = a made-up token on the app target, in `Debug-Staging` and `Release-Production`, beside `MARAUDERS_API_BASE_URL`. Letters, digits and `-` only.
- `Info-Additions.plist`: `MARAUDERS_CLIENT_KEY` is `$(MARAUDERS_CLIENT_KEY)`, with a one-line comment.
- `Shared/Configuration/ClientKey.swift`, shaped like `APIBaseURL`: reads the Info.plist key; trims it; counts it as none when it is blank, holds a control character, or is still the literal `$(MARAUDERS_CLIENT_KEY)` (a setting that never expanded). Its descriptions show `<redacted>`, never the value.
- `DebugLogView` (Staging only): the subtitle adds `client key: set` or `client key: missing`, as `Text(verbatim:)`.

**Jenkins and fastlane**

- `fastlane/Fastfile`, lane `build`, beside the build number: when the environment variable `MARAUDERS_CLIENT_KEY` is non-empty, add it to xcargs, shell-escaped.
- `Jenkinsfile`, Deploy stage: bind `string(credentialsId: 'marauders-client-key', variable: 'MARAUDERS_CLIENT_KEY')` next to `asc-key-id`. The owner creates the credential (Secret text) in Jenkins; nobody else sees the value. A missing credential stops the Deploy stage before it builds, so Jenkins cannot ship the mock by accident.

**Docs**

`docs/ci-cd.md` (the credentials table, the value Jenkins injects, how to read it back from the .ipa because Production has no log) and one line in `README.md`.

## Proof owed

- Swift Testing for `ClientKey`: the configured value; trimming; blank, a control character and the unexpanded literal give none; the descriptions hide the value; the built app always carries a value.
- Script tests (`cd backend && npm test`): both app configurations define a non-blank default; Info-Additions hands the setting to Info.plist; the Fastfile passes it; the Jenkinsfile binds `marauders-client-key` in the Deploy stage; `docs/ci-cd.md` lists the credential.
- Real builds on the iOS 27.2 simulator and unsigned archives: Staging runs and shows `client key: set`; a Production archive with no override holds the mock and passes the guard; the same archive given the Fastfile's argument holds an injected throwaway value, also one with a space and a `$`.
- Not provable without the owner: the Jenkinsfile binding itself. Only a Build Now shows it, and a Build Now uploads to TestFlight; a push comes first, because Jenkins reads GitHub.

## Left to the builder

The mock's exact text, file and test names, and the wording of the Thai docs.

## My calls

For the owner to check:

1. Names: `MARAUDERS_CLIENT_KEY` and the credential `marauders-client-key`.
2. No Debug environment-variable override: the project default covers testing, and one can be added later as `APIBaseURL` has.
3. The value is stripped of surrounding whitespace and shell-escaped in xcargs, so a credential pasted with a line break, or holding a space or a `$`, cannot break the command.
4. `ClientKey` redacts its descriptions although the value is a mock today: it costs a few lines and keeps a later real value out of logs.

Added while writing the plan, also for the owner to check:

5. Two docs the design did not name get a sentence each, so none lists the Jenkins credentials or the build-time values without the new one: the credentials list in `deployment/README.md` and the build-time bullet of `ARCHITECTURE.md`.
6. The mock is `mock-client-key-local-only`, and a script test pins that a default starts with `mock-`, so a real value cannot be committed there by accident.
