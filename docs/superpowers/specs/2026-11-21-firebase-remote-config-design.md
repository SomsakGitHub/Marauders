# Force update from Firebase Remote Config (in place of a Worker route)

Status: approved by the owner 2026-11-21; built and tested, and proved on the simulator against the owner's Firebase project (2026-11-22); not in a TestFlight build yet. It changes only where the gate's two numbers come from; the gate
itself (the rule, the screen, the kept answer, the tests) was built and tested earlier on branch `force-update`
and is described in `docs/adr/012-force-update.md`. Built with one change to the start-up guard below: it reads four keys of the plist, not the
app id alone (the first run with a fixture plist crashed the app on a placeholder API key; ADR-012 has the rules).
Size: small (one new Data repository, one package, one lane check, docs). A short design, so no separate builder check.

## Intent and why

The owner wrote "เอา Firebase Remote Config มาใช้" (2026-11-21) right after the first-party gate (a public `GET /v1/config` on the Worker)
was built and tested, and then picked "แทนที่ Worker" when asked whether Firebase should replace that route or run beside it. Nothing
else in this document was decided by the owner: every other choice is marked **my call**, with its reason.

The one sentence that has to become true: *when the owner publishes a higher `minimum_build` in the Firebase console, a build below it
shows the Update screen and does nothing else, and a build at or above it never notices. No commit, no deploy.* (My reading of why it
is worth it: raising the minimum becomes a button in a console, and the console is where later flags would go.)

## Goals, non-goals, anti-goals

Goals
1. Firebase Remote Config is the only source of the minimum build and of the Update link.
2. Everything else the gate promised still holds: the rule of `UpdateDecision`, the Update screen, a decision from the kept answer at
   launch (so it works offline), no waiting on the network, DEBUG never stopped (build 1 too, until the owner took that exemption out on
   2026-11-22: ADR-012), fail open.
3. A plain Run from Xcode with no plist behaves as it does today: no crash, the gate stays open.

Non-goals
- Other flags, conditions, percentages, A/B tests, real-time updates. Possible later in the same console; none is built now.
- Any other Firebase product (Analytics, Crashlytics, Messaging, Auth). Without Analytics there is no ATT prompt and no audience conditions.

Anti-goals (a failure even if the code works)
- A crash on a missing or malformed plist. The SDK raises an Objective-C exception, which Swift cannot catch: `configure()` when it finds
  no valid plist, and any start whose GOOGLE_APP_ID is missing or not `1:<number>:ios:<hex>` (read in `FIRApp.m`, 2026-11-21). The
  first draft named the app id only; building it found three more keys the SDK raises on while it starts (API_KEY of 39 characters,
  PROJECT_ID, GCM_SENDER_ID), and the guard now reads all four.
- A shipped build whose plist is missing or belongs to another app, so the gate is silently unarmed and nobody finds out until the minimum
  is raised. The SDK only logs a bundle ID mismatch and carries on (`checkExpectedBundleID`); what the backend then does is not known.
- A build-time failure on a scheme the owner runs from Xcode (the lesson of the client secret). The Production guard is not touched.
- The app reaching Google before the pass check, or in a UI test, or on the path to the first frame.
- A new exception in the layer checker, or a Firebase import outside Data and Composition.

## Constraints found (verified 2026-11-21)

- firebase-ios-sdk 13.2.0 (16 Nov 2026) needs Xcode 26.2 or later and iOS 15 or later. A scratch package outside the repo, built with
  Xcode 27.2 (Swift 6.4.2) in Swift 6 mode with MainActor default isolation, compiled with 0 warnings, the async `fetchAndActivate` and
  `ensureInitialized` included. That is a compile only: never linked into the app, run, or given a plist or a network.
- The SDK's defaults: a fetch at most every 12 hours (`minimumFetchInterval` 43 200 s) and a 60 s timeout. It calls
  firebaseremoteconfig.googleapis.com and firebaseinstallations.googleapis.com (a third host only for real-time updates).
- Privacy: the SDK's own manifests declare "Other Diagnostic Data" collected and no tracking, and Firebase's disclosure page adds country,
  language, time zone, OS version and the app and bundle ID (for targeting). The App Store Connect answers are the owner's. Remote Config
  values are not private: nothing confidential goes in them.
- Staging and Production share `com.somsak.Marauders`, so one Firebase iOS app (one plist) serves both schemes and both read the same values.
- The app target uses synchronized folders: a file placed in `Marauders-ios/Marauders/` joins the bundle. Adding a package still edits
  `project.pbxproj` and `Package.resolved` (13 packages, about 1.4 GB of clones on the first resolve).
- Jenkins already binds a file credential (`asc-api-key`) in its Deploy stage, the `build` lane already injects build-time values, and
  `docs/ci-cd.md` reads `CFBundleVersion` and the client key back from the .ipa.
- The gate is source-agnostic: only `DefaultAppConfigRepository`, `AppConfigAPIClient` and `APIConfiguration.appConfigURL()` talk to the Worker.

## Approaches

- **A. Firebase replaces the Worker route (picked by the owner).** One new Data repository over the SDK; the Worker route, its vars and
  its tests are taken out.
- B. Both: the Worker keeps the gate and Firebase waits for flags. Two config systems for one value in use. Not picked.
- C. The first-party route alone (built, tested, never committed). Set aside by the owner's request; the ADR keeps it as an alternative.
- Inside A, **the plist** (my call): kept out of git and injected by Jenkins like the other build-time values. The repo is public
  (`docs/ci-cd.md`), and a Google API key in a public file draws secret-scanning alerts and puts the project's identifiers in the open,
  even though Google documents such keys as identifiers rather than secrets (not re-checked today). Committing it would be smaller (no
  credential, no lane check, no missing-plist case), which is why this is named here.

## The design (all my call except A)

### What the owner publishes
Two parameters in the console: `minimum_build` (Number; 0 or empty means no gate) and `update_url` (String; the Update button's link).
The app reads both as text and parses the number by the rule it already applies to its own build number (digits only), so "12o", "1.5",
"-3", "+5", a number too large for an Int and an absent parameter all count as 0 (spaces or a line break around good digits are ignored,
as for the build's own number). A link that is not https on apple.com is ignored by
`UpdateDecision`, as before. A typo can therefore lift the gate or set it too high; no code can tell the second from a wish, and the undo
is publishing 0. The app sets no in-app defaults: an absent value reads as empty, which is 0.

### The app (Data and Composition; Domain, Presentation and the Update screen do not change)
- `FirebaseAppConfigRepository: AppConfigRepository` replaces `DefaultAppConfigRepository`: the same kept answer (UserDefaults
  `update.appConfig.v1`, JSON of `AppConfig`, read at once by `cached()`), the same logs under `update`, with the Worker client swapped
  for a small protocol, a source that returns the two texts or nil. `refresh()` parses them, keeps the answer only on success, and
  returns nil on any failure, a cancellation included, leaving what is kept as it was.
- `FirebaseRemoteConfigSource` is the only file that imports Firebase. At the first ask it starts Firebase, then runs `fetchAndActivate`
  with a minimum fetch interval of 1 hour and a fetch timeout of 10 seconds; an error, a throttle or an unusable plist answers nil.
  Why 1 hour: the SDK's 12 hours would make a raise reach devices too slowly, and it still caps a device at one real fetch an hour however
  often the app opens; the view model's own 10-minute rule stays on top. Why 10 seconds: a hung fetch frees the gate's single in-flight
  slot in 10 seconds, not 60.
- Start-up guard, a pure function unit-tested with a valid plist, a missing one, a malformed one and one without a usable GOOGLE_APP_ID:
  `FirebaseApp.configure(options:)` runs only when no app is configured yet, the plist is in the bundle, it reads as a dictionary and its
  GOOGLE_APP_ID, API_KEY, PROJECT_ID and GCM_SENDER_ID are what the SDK demands (as built; the draft named the app id only). Otherwise it
  logs once and answers nil, so the gate stays open. The builder validates from
  the plist's own dictionary before the SDK sees the file.
- The SDK is never started at launch, only by the first ask, which `MaraudersApp` already makes after the pass check. That first call must
  not run on the first frame's path; the builder checks it against the launch log. (As built: the plist read, its check and the
  network run off the main actor, and only the call that starts the SDK runs on it, once, because the SDK's header asks for that
  and its failure cannot be caught; ADR-012.)
- `UpdateGateComposition.makeViewModel` takes the source in place of the HTTP client. Under UITEST it still picks
  `UITestAppConfigRepository`, so no UI test ever builds the Firebase source.
- Taken out: `AppConfigAPIClient`, `APIConfiguration.appConfigURL()` and the tests that go with them.

### Build and release
- `firebase-ios-sdk`, "up to next major" from 13.2.0 like lottie, products `FirebaseCore` and `FirebaseRemoteConfig` only.
- The plist lives at `Marauders-ios/Marauders/GoogleService-Info.plist`, git-ignored. Jenkins binds it as the file credential
  `marauders-firebase-plist` next to `asc-api-key`, and the `build` lane copies it into place when `FIREBASE_PLIST_PATH` is set.
- A build that ships needs it: the `beta` lane (TestFlight, never an Xcode Run) stops before building when the plist is missing, its
  BUNDLE_ID is not `com.somsak.Marauders`, or one of its four keys is one the SDK cannot start from (as built: the same four as the
  start-up guard). No scheme and not the Production guard script change.
  A script test pins the Jenkinsfile and Fastfile wiring, and the first TestFlight build is read back from the .ipa (plist and
  `CFBundleVersion`), as the client key is.

### The Worker work that goes
The route (`backend/src/appConfig.ts` and its wiring in `index.ts`), the two vars in `wrangler.toml`, `test:config` and the parity
entries. `clientKeyInjection.test.mjs` stays: it pins the window's shape and that the refresh follows the pass check, both still true;
only its message stops naming the Worker. Nothing of it was ever deployed, so production is untouched. Because nothing is committed, the
removed files and the tracked diffs are first saved as a patch under the git-ignored `.superpowers/sdd/kept-worker-config-route/`, and the
memory notes say where.

### Docs
ADR-012 is rewritten around Firebase (the Worker route becomes an alternative: built and tested, replaced before shipping, with the
reason); `ARCHITECTURE.md`, `README.md`, `docs/adr/README.md`, `deployment/README.md` (raising the minimum becomes the console's steps,
no deploy) and `docs/ci-cd.md` (the plist credential). The earlier first-party design and plan are not committed, like other cancelled
work; they go into the same patch folder. This design and its plan are committed.

## What "done" includes

- Unit tests, each watched failing first: the repository (the parse table above, the entry written only on success, nil leaves it, an
  unreadable entry removed: ported from `AppConfigRepositoryTests`), the start-up guard, the composition (the build 1 and DEBUG
  exemptions, UITEST). The decision, use case, view model and UI tests stay as they are and stay green (the build-1 exemption was taken
  out on 2026-11-22, and the decision, use-case and composition tests changed with it: ADR-012).
- Gates: layer checker `--strict` with the 9 exceptions unchanged, plain strings, swift-format, backend `npm test` green without the
  config runner, a Production archive built with the plist and one without it (the second still builds), the plist found in the built app.
- With the owner's plist, on the simulator: the Staging run logs `config refreshed: minimumBuild=0`; after the owner publishes
  `minimum_build` 5 and a link, a Release-Production build with `CURRENT_PROJECT_VERSION=2` shows the Update screen from the real
  console; after the owner publishes 0 it lifts. Each step is a fresh install, which clears the SDK's fetch timer. This is the proof
  the first-party design could only give after a TestFlight build. Still unproved until the first TestFlight build: the Update button
  opening the link, and the TestFlight path itself.

## Rollout (each step the owner's yes)

1. The owner: a Firebase project with Google Analytics off, an iOS app `com.somsak.Marauders`, the downloaded plist, and the parameters
   `minimum_build` (Number, 0) and `update_url` (String, empty), published. The code can be written and tested before this.
2. The owner: the file credential `marauders-firebase-plist` in Jenkins, and the App Store Connect privacy answers before a build goes
   beyond the owner's own devices.
3. Commits and a push, then a TestFlight build, the first that holds the gate.
4. To force an update: when build N can be installed, publish `minimum_build` = N and `update_url`; never above the newest uploaded
   build. To undo, publish 0: no deploy and no rollback.

## Known limits (new against the first-party design)

1. A console edit has no review, test or commit: the rule in the app is the only guard. A link off apple.com blocks nobody; a minimum
   set too high blocks everyone, and only the undo helps.
2. A raise or an undo reaches a device once the SDK's hour has passed and the app is launched or foregrounded (the first-party route
   took 10 minutes). A real-time listener would shorten it; it is not built.
3. A build that cannot reach Firebase, or has no plist, keeps what it knows: a build that already holds "required" stays stopped.
4. Staging and Production read the same values and share one kept answer (as before).
5. What changes for a plain Run from Xcode: the first build after the merge resolves and compiles Firebase (slow once). Without the
   plist everything works as today; with it, the app asks Firebase and logs the answer.

## Left to the builder

Names and file layout, how the SDK object crosses the Sendable boundary under MainActor default isolation, how `project.pbxproj` and
`Package.resolved` are edited and regenerated, the exact SDK settings after reading its docs, the log lines, the script test's patterns,
the wording of the lane's error.

## Left to the owner (none of it blocks the code)

The console steps and the plist, the Jenkins credential, the App Store Connect answers, the Update URL (a TestFlight link now, the
App Store later), the Thai wording of the three Update strings (unchanged), and every production step: a commit, a push, a TestFlight
build, each raise of the minimum.
