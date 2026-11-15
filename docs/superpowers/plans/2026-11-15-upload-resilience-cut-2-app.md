# Upload Resilience, Cut 2 (App): a Background Upload Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clip the viewer has sent to upload keeps going when they leave the app, lock the phone, lose the network for a while or have the app ended by the system, arrives exactly once, and the Upload tab shows how it ended when they come back.

**Architecture:** Tapping Upload stages the multipart body into a file under Application Support next to a durable record whose id doubles as the `Idempotency-Key`, and hands the file to a background `URLSession`. An actor, `BackgroundClipUploader`, behind the Domain protocol `ClipUploading`, owns the record's state machine; it is fed by an ordered stream of session events and reconciled at every launch. `UploadVideoViewModel` only watches `UploadSnapshot`s through use cases, and a launch by the system for the session's events reaches the actor through the route Task 1 picks (a scene `.backgroundTask`, or an app delegate).

**Tech Stack:** Swift 6.4 (Xcode 27.2) with default MainActor isolation, SwiftUI, Swift Testing, `URLSession` background configuration, an actor and `AsyncStream`.

**Spec:** `docs/superpowers/specs/2026-11-15-upload-resilience-design.md`, "Design: cut 2, the app", with "Goals", "Non-goals", "Anti-goals", "Verification", "Rollout, order and rollback" and "Risks to measure early". Read it first. The Worker half is the sibling plan `docs/superpowers/plans/2026-11-15-upload-resilience-cut-2-worker.md`: nothing here needs it until the device checks at the end, because the tasks run against fakes and a loopback server. Cut 1 (progress, streaming, the safety net) has landed as `b78a9d7`.

## Global Constraints

- **Scope:** the app, its docs and one privacy-manifest entry. No Worker change (the sibling plan), no new dependency, no `Info.plist` change: a background `URLSession` needs no background mode, and Task 1 proves the relaunch without one. If it does not relaunch, report that; do not add `UIBackgroundModes` to try to fix it. The avatar and dubbed-audio uploads keep `HTTPClient.upload`, and every installed build keeps working.
- **Session (exact):** identifier `com.somsak.Marauders.upload`; `isDiscretionary = false`; `allowsCellularAccess`, `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` all `true`; `timeoutIntervalForResource = 24 * 60 * 60`; `sessionSendsLaunchEvents = true`. One instance per process, created in `MaraudersApp.init` before any view exists, so a relaunch by the system finds the session by its identifier.
- **Request (exact):** `POST` to `APIConfiguration.videoUploadURL()` with `Authorization: Bearer <token>`, `Content-Type: multipart/form-data; boundary=<the recorded boundary>` and `Idempotency-Key: <record id, lower-case>`; `request.timeoutInterval = 300`; `uploadTask(with:fromFile:)` on the staged body; `taskDescription` = the record id (lower-case); `countOfBytesClientExpectsToSend` = body bytes + 1024; `countOfBytesClientExpectsToReceive` = 65_536.
- **Body and record (exact):** `Application Support/PendingUpload/<id>.multipart` and `<id>.json`; the directory is excluded from backup; default file protection, never `.complete` (a locked phone must still be able to read the body); boundary `marauders.boundary.<UUID>` kept in the record. Record `version` 1 holds `id`, `accountSubject`, `bodyFileName`, `boundary`, `byteCount`, `createdAt` and `state`, and nothing else: no token, caption, coordinates or clip path. One slot. A record is deleted 7 days after its stored `createdAt` (never from a file date: file-timestamp APIs are privacy-manifest APIs).
- **Free space:** fewer than the clip's byte count + 50 MiB (`52_428_800`) available (`volumeAvailableCapacityForImportantUsage`) fails before anything is written. That is a required-reason API, so `Marauders-ios/Marauders/PrivacyInfo.xcprivacy` gains `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1` (Task 4); without it App Store Connect refuses the build.
- **Response body:** kept up to 65_536 bytes per upload.
- **Failure texts (exact; English):**

  | Failure | Message | Try again |
  |---|---|---|
  | `rateLimited` | Too many uploads, try again in a minute | yes |
  | `sessionEnded` | Your session ended. Sign in to try again. | yes |
  | `unavailable` | The service is unavailable right now. Try again. | yes |
  | `interrupted` | The upload was interrupted. Try again. | yes |
  | `responseLost` | The clip may have been uploaded, but the answer was lost. Try again. | yes |
  | `bodyMissing` | The clip is no longer on this iPhone. Choose the video again. | no |
  | `connection(text)` | the transport's own text | yes |
  | `rejected(text)` | the Worker's `error` text, else `Upload failed (status N)` | no |
  | `serverError(text)` | the Worker's `error` text, else `Upload failed (status N)` | yes |

  Start errors (`ClipUploadError`): `Uploading is not available`, `An upload is already in progress`, `Not enough free space on this iPhone to upload the clip`.
- **Progress:** `UploadSnapshot.uploading(fraction:)` is always below 1; a fraction of 1 is `finishing`, so nothing reads 100% before the Worker has answered. The uploader persists and publishes only when the whole percent (`Int(fraction * 100)`) changes. The label texts stay cut 1's: `Uploading… 42%` (rounded down) and `Finishing…`.
- **Logs:** `AppLog` category `upload.bg`; the first 8 characters of the record id and a state name, never a token, path, caption, coordinate or response body.
- **Isolation** (app target default MainActor): new Data types are `nonisolated`; so are the Domain types `UploadSnapshot`, `ClipUploadRequest`, `ClipUploading`, `ClipUploadError` and `IdleClipUploader` (an actor can conform only to a nonisolated protocol, as `TokenRefresher` does to `TokenRefreshing`). `APIAccessTokenStore` is a main-actor protocol, so the actor reads a token with one `await`, as `TokenRefresher` does; a test double that conforms to it is a `nonisolated final class … @unchecked Sendable` with a lock (see `SignOutSessionStorage`). If the compiler objects to `FeedVideo`, `ClipLocation` or `ClipAudioAssessment` being used from the actor, mark that type `nonisolated` (as `TokenRefreshOutcome` and `APIAccessTokenSubject` are) instead of hopping to the main actor.
- **Actor discipline:** after every `await` inside a state transition the uploader reads the record again and stops when it is gone or no longer in the state it expected (actor reentrancy). An event for a record that no longer exists is ignored and recreates nothing. The uploader never signs anyone out and never clears a store: it reports a rejected token through a reporter the container may set, and works with none. It never needs the container or a view (an anti-goal of the spec: a background launch must finish an upload alone).
- **Layers** (`Scripts/check-layers.sh`): Domain imports Foundation only; Data names no Presentation type and imports no SwiftUI, and this plan's Data code imports no UIKit either (whether the app is active is a closure the container hands over); Presentation names no Data type; a `*View.swift` names no use case or repository. No new line in `Scripts/layer-exceptions.txt`.
- **Format and Xcode:** swift-format `lineLength` 120; new files in the synchronized groups need no `project.pbxproj` edit; all targets are iOS 27.0.
- **The old foreground path:** after Task 9 nothing wires `UploadFeedVideoUseCase`, `VideoUploadRepository`, `DefaultVideoUploadRepository` or `VideoUploadAPIClient.upload`. They and their tests stay, unwired, because Task 1's STOP case needs them; deleting them is the owner's call afterwards.
- **Git:** stage exactly the paths listed under a task's **Files**, never `git add -A`. Work in a worktree. The owner's main checkout has an unrelated uncommitted edit in `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift`; this plan never touches that file, so the merge should not collide (check with `git merge-tree --write-tree --name-only main <branch>` before merging, which prints a bare tree id when clean). Commit, push, merge, a TestFlight build and every real upload from the phone each need the owner's yes.

## Review Focus

Five inputs the spec implies and a happy-path test would miss, most likely first, each pinned by a test:

1. **A late or reentrant event** (a completion after Discard, after sign-out or after the "interrupted" verdict; a refresh still out when the viewer discards). Expect nothing written back, no file recreated, no snapshot published, and a real success that arrives after `failed(interrupted)` to win. Pinned by Task 5 `aCompletionForADiscardedRecordChangesNothing` and `aDiscardWhileStartWaitsForTheRefreshStartsNothing`, Task 6 `aDiscardWhileTheRefreshIsOutLeavesNothingBehind` and `aCompletionThatArrivesAfterTheInterruptedVerdictWins`, Task 7 `aDiscardWhileRetryWaitsForTheRefreshSubmitsNothing` and `aSecondRetryWhileTheFirstWaitsForTheRefreshSubmitsOnce`.
2. **A 2xx whose body never reaches the app, then Try again.** Expect the empty-body replay to fetch the stored clip, a failed replay to say `responseLost`, and Try again to reuse the record id, so the Worker can never make a second clip. Pinned by Task 6 `aSuccessWithoutABodyAsksTheWorkerForTheStoredClip` and `aReplayThatFailsLeavesAResponseLostFailure`, Task 7 `retryReusesTheRecordIdAsTheKeyAndSendsTheSameBody`.
3. **Another account signs in on the same phone.** Expect the earlier account's record and body deleted at launch, at sign-in and on Try again, never uploaded under the new account; an unreadable `sub` counts as different; with no token stored the record is kept. Pinned by Task 7 `aRecordOfAnotherAccountIsDeletedAtLaunch`, `anUnreadableSubjectCountsAsAnotherAccount`, `withNoTokenStoredTheRecordIsKept`, `retryForAnotherAccountDeletesTheRecord`, Task 10 `signingInChecksTheStoredUploadBeforeTheViewerIsSignedIn`.
4. **A clip, caption or location left on disk** after any ending (finished, a 4xx, Discard, sign-out, 7-day expiry, an orphan body, a purged body, no free space). Expect body and record gone (a finished record stays only until the viewer has seen it). Pinned by Task 4 `aRecordHoldsNothingButItsOwnFields` and `anOrphanBodyIsRemovedAndABodyWithARecordIsKept`, Task 5 `aSuccessWithABodyFinishesTheUploadAndDeletesItsBody` and `notEnoughFreeSpaceStagesNothingAndSubmitsNothing`, Task 6 `aRejectedUploadDeletesItsBodyAndIsNotRetried`, Task 7 `anOldRecordIsDeletedWithItsBody`, Task 10 `signingOutDiscardsTheUploadBeforeTheSessionIsCleared`.
5. **The app is not active when the upload ends, and a bar that says 100% too early.** Expect the finished clip reported to the feed once, when the app is next active and never again after a relaunch, and `Finishing…` rather than 100% until the Worker has answered. Pinned by Task 4 `aFractionOfOneIsFinishingNotUploading`, Task 9 `aFinishedUploadIsReportedOnceWhenTheAppIsActive`, `aFinishedUploadWaitsForTheAppToBecomeActive` and `allBytesSentShowsFinishingNotOneHundredPercent`.

Also pinned, because the spec lists them: the 401 healed once and a second 401 ending the session (Task 6); no automatic resubmission after a 502/503/504 or a transport failure (Task 6); one slot, and a start that races a start (Task 5); an upload that finishes with no container and no reporter (Task 6 `aSessionEndWithNoReporterStillFails`); a stuck Discard never holding a sign-out back (Task 10 `aDiscardThatNeverReturnsDoesNotHoldTheSignOutBack`); the privacy manifest declaring the free-space check (Task 4 `theManifestSaysWhyTheAppChecksFreeSpace`); the Upload tab never ending in a spinner that does not end (a goal of the spec): the 24 h resource timeout (Task 8 `theConfigurationHasTheSpecsFlags`) and an `uploading` record with no task becoming `failed(interrupted)` at launch (Task 7 `anUploadingRecordWithNoTaskBecomesInterrupted`).

## How to run things

- **Paths** are relative to `Marauders-ios/` (app code under `Marauders/`, tests under `MaraudersTests/`), except `docs/...` and `ARCHITECTURE.md`, relative to the repository root. Commands run from the worktree's root.
- **Tests run on the iOS 27.2 simulator** (the owner's rule; the phone only when the owner asks). `$SCRATCH` is a throwaway folder outside the repo:
  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme Marauders \
    -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' \
    -derivedDataPath "$SCRATCH/DerivedData-sim" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" \
    -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
  ```
  If a run says the device is busy: `xcrun simctl boot <id>` then `xcrun simctl bootstatus <id> -b`. A "Run" step uses this command with the suites it names; read the result by grepping the output for ` error: ` and `✘`; a pass ends with `** TEST SUCCEEDED **`; a compile error is the expected state of every "see it fail" step. Suites run in parallel, so a test that depends on wall-clock time can flake under load: run it alone before reading a red as real. The whole unit target (`-only-testing:MaraudersTests`) was 1061 tests before this work and about 5 s of test time once built.
- **UI target** (52 tests, 16 to 34 minutes): once, in Task 11, detached: `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c "xcodebuild test <same arguments> -only-testing:MaraudersUITests > $SCRATCH/ui.log 2>&1; echo exit=\$? >> $SCRATCH/ui.log"`, then wait for `exit=` in the log. Baseline 51 of 52: the red is `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` (a system Translate sheet the simulator shows). A test cut short by a crash of Xcode's `testmanagerd` has no `error:` line: run it alone before reading it as a regression. macOS has no `timeout` command.
- **Layer checker:** `sh Marauders-ios/Scripts/check-layers.sh` prints nothing when clean. **swift-format:** `cd Marauders-ios && xcrun swift-format lint <files>` prints nothing when clean. **Release compile check:** `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme Marauders -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/DerivedData-release" -archivePath "$SCRATCH/Marauders.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`.
- **The phone (Task 1 Part B only):** `xcrun devicectl list devices`, `xcrun devicectl device process launch --device <id> --console <bundle id>` for the log, and `xcrun devicectl device process terminate --device <id> --pid <pid>` to end the process (pid from `xcrun devicectl device info processes --device <id>`; `xcrun devicectl device process --help` shows the flags if they differ). Never end the process by swiping the app away: iOS cancels background transfers then, which is a different case.

## File Structure

| Area | Create | Modify |
|------|--------|--------|
| Domain | `Entities/UploadSnapshot.swift`, `Entities/ClipUploadRequest.swift`, `Services/ClipUploading.swift` (protocol, `ClipUploadError`, `IdleClipUploader`), `UseCases/ClipUploadUseCases.swift` | `Auth/APIAccessTokenStore.swift` (`nonisolated enum APIAccessTokenFormat`) |
| Data | `API/VideoUploadForm.swift`; `Upload/UploadRecord.swift`, `UploadRecordStore.swift`, `UploadBodyStager.swift`, `BackgroundUploadSession.swift`, `BackgroundClipUploader.swift`, `BackgroundClipUploader+Completion.swift`, `BackgroundClipUploader+Launch.swift`, `SystemBackgroundUploadSession.swift`, `IdempotentReplayResolver.swift` | `API/VideoUploadAPIClient.swift` |
| Presentation | | `Upload/UploadVideoViewModel.swift`, `Upload/UploadVideoView.swift`, `Auth/AuthViewModel.swift`, `Splash/AppRootView.swift` |
| Composition, App | `App/MaraudersAppDelegate.swift` (only if Task 1 picks route B) | `Composition/AppDependencyContainer.swift`, `App/MaraudersApp.swift`, `PrivacyInfo.xcprivacy` |
| Tests (`MaraudersTests/`) | `ClipUploadUseCasesTests`, `IdleClipUploaderTests`, `VideoUploadFormTests`, `UploadRecordTests`, `UploadRecordStoreTests`, `UploadBodyStagerTests`, `PrivacyManifestTests`, `BackgroundClipUploaderStartTests`, `BackgroundClipUploaderCompletionTests`, `BackgroundClipUploaderLaunchTests`, `SystemBackgroundUploadSessionTests`, `IdempotentReplayResolverTests`, `UploadVideoViewModelUploadTests`, `AuthViewModelUploadHooksTests`; `Support/FakeClipUploader.swift`, `Support/FakeBackgroundUploadSession.swift`, `Support/UploaderKit.swift` | `UploadVideoViewModelTests`, `AppCoordinatorTests`, `AppDependencyContainerWiringTests` |
| Docs | `docs/adr/008-background-upload.md`, `docs/superpowers/notes/background-upload-spike.md` | `ARCHITECTURE.md`, `docs/adr/README.md` |

## Calls this plan makes (beyond the spec; the owner may overrule any)

1. **Cut 2 is two plans** (this one and the Worker's). The spec says cut 2 gets one plan; the Worker half is small, independent, backwards compatible and deploys in a different order, and the skill's scope check says to split independent subsystems.
2. **The spike gates Tasks 5 to 10, and its thresholds are mine** (D1 to D3 in Task 1). Tasks 2 to 4 need no answer from it. Part A runs on the simulator unasked; Part B uploads a real clip to the production Worker and is the owner's call.
3. **The old in-process video path stays, unwired** (see Global Constraints). The spec says the video upload uses the background path only; wiring does that, and keeping the types costs nothing until the owner decides.
4. **`ClipUploading` has five requirements.** The spec names start, observe, retry and discard; `reconcile` is added for the launch and sign-in checks. Acknowledging a finished upload is `discard`. `UploadSnapshot` gets an `idle` case (no record), because the stream's first value must exist. `ClipUploadUseCases` bundles the five use cases so the view model, the container and the tests take one argument.
5. **The empty-body replay is always built** (`IdempotentReplayResolver`): the spec flags that a background upload's response body may never reach the delegate, and the Worker answers a stored key without reading a body, so a 2xx with no body is resolved by asking again.
6. **`UploadPolicy.resubmitsWhileInBackground` is set from the spike** (D2). A 401 that cannot be resubmitted leaves `failed(interrupted)`: the new token is good, a plain Try again works.
7. **An unreadable `sub` counts as another account; no stored token keeps the record.** Age counts from `createdAt`. Sign-out's Discard and the sign-in check are each bounded to 3 s (`TimeBoundedCall`), so neither holds the viewer back; a Discard that times out is caught later by the `sub` check.
8. **The sign-in check runs before `isSignedIn` turns true**, so the new account never sees the earlier account's snapshot for a moment.
9. **A finished record is deleted, then reported:** the view model discards it first and calls `onUploaded` after, so a crash in between loses only the "focus the clip" step, never reports twice.
10. **`awaitSystemEvents` is a latch**: it returns once the session's "events finished" marker has been applied (or at once if one is waiting), after 25 s at most, and one call consumes one marker. The system gives a relaunch about 30 s.
11. **The 50 MiB margin, whole-percent persistence, the failure texts and the one-slot message texts** are the builder's calls the spec leaves open.
12. **No UI test is added.** No UI test covers upload today, and a real upload reaches the production Worker. Two accessibility ids are added (`upload.retry`, `upload.chooseAnother`).
13. **The uploader is split over three files by behaviour** (`BackgroundClipUploader`, `+Completion`, `+Launch`); its stored state is internal, not private, so the extensions can reach it.
14. **A discard wins over a `start` or a `retry` that is waiting.** The spec's table covers a completion that arrives after a Discard. The same window opens in `start` (while the token is traded and while the body is staged) and in `retry` (while the token is traded): sign out then, and the upload would still go out after the viewer left. Every uploader method that awaits compares a discard counter or reads the record again afterwards, and stops when the viewer got there first.
15. **Cut 1's deferred Minors 5 to 7 are not taken.** 6: the body no longer lives in `NSTemporaryDirectory()`, and `removeOrphanBodies` sweeps strays at launch. 7: the part header's mime type is one of the two fixed strings `VideoUploadForm.validatedSize` lets through. 5: nothing in the app cancels the Upload button's task, and a Discard is handled by call 14.

## Before Task 1

- [ ] Ask the owner once, in one message: (a) commit the two cut 2 plan files as one commit on `main`; (b) work in a worktree on its own branch, `claude/upload-resilience-cut-2-app` (`superpowers:using-git-worktrees`), cut from `main`; (c) may each task's local commit below be made as the task passes. A push, the merge, a TestFlight build and every real upload from the phone are asked separately, each time (Task 1 Part B carries its own ask). The Worker plan runs in its own branch; merge it first (see "After the last task").

---

### Task 1: Spike: what a background session does here, and three decisions (the gate for Tasks 5 to 10)

**Files:**
- Create: `docs/superpowers/notes/background-upload-spike.md`
- Throwaway, never committed (check `git status` before the commit): `MaraudersTests/SpikeBackgroundSessionTests.swift` for Part A; for Part B a Debug-only button on the Upload tab in a local build for the phone.

**Interfaces:**
- Produces three decisions, written in the note and read by later tasks: **D1** whether a foreground upload is deferred (a STOP, below); **D2** the value of `UploadPolicy.resubmitsWhileInBackground` (Task 5); **D3** the relaunch route, Variant A or B (Task 10).

- [ ] **Step 1: Part A, on the simulator, no owner input.** A throwaway test with a `URLSessionConfiguration.background(withIdentifier:)` session (a fresh identifier per run), a delegate that logs every call with a `ContinuousClock` stamp, `LoopbackHTTPServer` (cut 1) at `http://127.0.0.1:<port>/` as the receiver, and a 3 MB file sent with `uploadTask(with:fromFile:)` and a `taskDescription`. Write down: (A1) which of `didSendBodyData`, `didReceive data`, `didCompleteWithError` and `urlSessionDidFinishEvents(forBackgroundURLSession:)` arrive, and in what order; (A2) whether the server's 201 body reaches `didReceive data`, and what `task.response` holds at completion; (A3) whether `getAllTasks` lists an in-flight task with its `taskDescription` (hold the answer with a second throwaway receiver that sleeps before it replies). The spec warns that the simulator runs background sessions only in part: what does not arrive is itself a result.
- [ ] **Step 2: Ask the owner for Part B**, naming what it does: with a throwaway Debug build on the phone (unlocked, on Wi-Fi, signed in), 8 to 12 uploads of one short clip (about 20 to 30 MB, picked through the normal Upload tab) go to the **production Worker**; each makes a real clip in the live feed that the owner deletes from the Profile tab afterwards; Network Link Conditioner is optional (it stretches an upload so a process can be ended mid-transfer). Wait for a yes. On a no, stop after Part A: Tasks 2 to 4 may go on, and Tasks 5 to 10 wait for the owner's word.
- [ ] **Step 3: Part B, on the phone.** Log with `AppLog` category `spike` and read it with `devicectl ... --console`. Measure, each with the numbers: (B1) foreground, three runs: time from `resume()` to the first `didSendBodyData`, and to completion; (B2) Home pressed right after the start, and (B3) the phone locked right after the start: the same two times; (B4) Airplane mode on for 20 s and off again mid-transfer: resumed, or reported as a failure, and with which error; (B5) a task created from a background wake (create one from the completion of an earlier one while the app is in the background), three runs: start delay; (B6) the process ended with `devicectl` mid-transfer (not a swipe): does iOS relaunch the app for the session's events through `.backgroundTask(.urlSession(id))` (a throwaway `.backgroundTask` on the scene) and, if not, through a throwaway `UIApplicationDelegateAdaptor` with `application(_:handleEventsForBackgroundURLSession:completionHandler:)`; how long after; (B7) does the Worker's response body reach `didReceive data`.
- [ ] **Step 4: Decide and write the note.** Date, device and iOS version, every observation with its numbers, and the decisions:
  - **D1.** Foreground is not deferred when, in 3 of 3 Wi-Fi runs, the first byte goes out within 15 s of `resume()`: build the plan as written. Any run over 60 s is a **STOP**: report to the owner, because cut 2 changes (the Upload tap would upload in the app while it is on screen and use the background session only when the viewer leaves, which this plan does not describe). A result between the two goes on, and the note says so.
  - **D2.** `resubmitsWhileInBackground = true` when a task created from a background wake starts within 2 minutes in at least 2 of 3 runs; otherwise `false`.
  - **D3.** Variant A (scene route) when it relaunched the app and delivered the events; otherwise Variant B (delegate); when neither delivered, a **STOP**.
  - A (A1 to A3) and B7 decide whether Task 8's loopback test can run on the simulator and how much the replay fallback matters; the fallback is built either way.
  Delete the throwaway code.
- [ ] **Step 5: Commit:** `git add docs/superpowers/notes/background-upload-spike.md` → "Record how a background upload session behaves on the simulator and the phone".

### Task 2: The Domain seam

**Files:**
- Create: `Marauders/Domain/Entities/UploadSnapshot.swift`, `Marauders/Domain/Entities/ClipUploadRequest.swift`, `Marauders/Domain/Services/ClipUploading.swift`, `Marauders/Domain/UseCases/ClipUploadUseCases.swift`, `MaraudersTests/ClipUploadUseCasesTests.swift`, `MaraudersTests/IdleClipUploaderTests.swift`, `MaraudersTests/Support/FakeClipUploader.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum UploadSnapshot: Equatable, Sendable {
      case idle                                 // no record
      case uploading(fraction: Double)          // 0 up to, never including, 1
      case finishing                            // every byte sent, no answer yet
      case finished(FeedVideo)
      case failed(message: String, canRetry: Bool)
  }
  nonisolated struct ClipUploadRequest: Sendable {
      let fileURL: URL; let mimeType: String; let clipLocation: ClipLocation
      let caption: String; let audioAssessment: ClipAudioAssessment?
  }
  nonisolated protocol ClipUploading: Sendable {
      func start(_ request: ClipUploadRequest) async throws
      func snapshots() async -> AsyncStream<UploadSnapshot>   // the current snapshot first, then every change
      func retry() async
      func discard() async
      func reconcile() async
  }
  nonisolated enum ClipUploadError: LocalizedError, Equatable, Sendable { case unavailable, alreadyUploading, notEnoughSpace }
  nonisolated struct IdleClipUploader: ClipUploading     // snapshots() yields .idle and ends; start throws .unavailable; the rest do nothing
  struct StartClipUploadUseCase: Sendable { init(uploader: any ClipUploading); func execute(_ request: ClipUploadRequest) async throws }
  struct ObserveClipUploadUseCase: Sendable { init(uploader: any ClipUploading); func execute() async -> AsyncStream<UploadSnapshot> }
  struct RetryClipUploadUseCase: Sendable { init(uploader: any ClipUploading); func execute() async }
  struct DiscardClipUploadUseCase: Sendable { init(uploader: any ClipUploading); func execute() async }
  struct ReconcileClipUploadUseCase: Sendable { init(uploader: any ClipUploading); func execute() async }
  struct ClipUploadUseCases: Sendable {
      let start: StartClipUploadUseCase, observe: ObserveClipUploadUseCase, retry: RetryClipUploadUseCase
      let discard: DiscardClipUploadUseCase, reconcile: ReconcileClipUploadUseCase
      init(uploader: any ClipUploading)
  }
  // Support: FakeClipUploader, a nonisolated final class with a lock, @unchecked Sendable
  //   init(snapshot: UploadSnapshot = .idle)
  //   var startError: (any Error)?;  var startGate: SignOutGate?;  var discardGate: SignOutGate?;  var onDiscard: (@Sendable () -> Void)?
  //   private(set) var started: [ClipUploadRequest]
  //   private(set) var retries: Int, discards: Int, reconciles: Int
  //   func emit(_ snapshot: UploadSnapshot)   // remembered as current and sent to every observer
  ```
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests.** `ClipUploadUseCasesTests`: `startForwardsTheRequestAndRethrowsTheUploadersError`; `observeYieldsWhatTheUploaderPublishesInOrder` (current `.idle` first, then two emitted snapshots); `retryDiscardAndReconcileEachReachTheUploaderOnce` (through `ClipUploadUseCases`). `IdleClipUploaderTests`: `theIdleUploaderPublishesIdleAndEndsItsStream`; `theIdleUploaderRefusesToStart` (`.unavailable`); `theStartErrorsReadAsTheirTexts` (the three exact texts of Global Constraints).
- [ ] **Step 2: Run** `ClipUploadUseCasesTests`, `IdleClipUploaderTests`. Expected: the build fails with `cannot find type 'ClipUploading' in scope`.
- [ ] **Step 3: Implement** the types above, `FakeClipUploader` included (its `snapshots()` yields the current value, then every `emit`; `start` waits on `startGate` and then throws `startError` when set). The use-case structs follow the neighbours (`StopLocationSharingOnSignOutUseCase`): no isolation mark.
- [ ] **Step 4: Run** the two suites and `sh Marauders-ios/Scripts/check-layers.sh`. Expected: pass; the checker prints nothing.
- [ ] **Step 5: Commit** the files under **Files** → "Add the Domain seam for a background clip upload".

### Task 3: One upload form for both paths

**Files:**
- Create: `Marauders/Data/API/VideoUploadForm.swift`, `MaraudersTests/VideoUploadFormTests.swift`
- Modify: `Marauders/Data/API/VideoUploadAPIClient.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum VideoUploadForm {
      static let maxUploadBytes: Int64                              // 100 MiB; VideoUploadAPIClient.maxUploadBytes now reads it
      static func validatedSize(of fileURL: URL, mimeType: String) throws -> Int64        // .unsupportedFormat / .fileTooLarge (empty or over the cap)
      static func parts(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
                        audioAssessment: ClipAudioAssessment?) -> [HTTPMultipartPart]
      static func request(authorizationHeader: String, boundary: String? = nil, idempotencyKey: UUID? = nil) throws -> URLRequest
      static func decodeItem(from data: Data) throws -> FeedVideo   // https stream URL, else VideoUploadAPIError.invalidResponse
      static func serverMessage(from data: Data) -> String?         // the body's "error" field
  }
  ```
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests** in `VideoUploadFormTests`: `partsAreLatitudeLongitudeSpeechCheckTrimmedCaptionThenTheFile` (the order and values of today's `multipartParts`, the file last as `.fileAt`); `anEmptyCaptionAndNoSpeechCheckAddNoPart`; `validatedSizeRefusesAnUnsupportedTypeAnEmptyFileAndAFileOverTheLimit` (a sparse file one byte over the cap, made with `FileHandle.truncate(atOffset:)`); `theRequestCarriesTheBearerTheBoundaryAndALowerCaseKey` (method POST, URL `APIConfiguration.videoUploadURL()`, `Authorization`, `Content-Type: multipart/form-data; boundary=…`, `Idempotency-Key` equal to `key.uuidString.lowercased()`, `timeoutInterval` 300); `aRequestWithoutBoundaryOrKeyCarriesNeither`; `decodeItemRefusesAStreamUrlThatIsNotHttpsAndABodyThatIsNotAClip`; `serverMessageReadsTheErrorField`.
- [ ] **Step 2: Run** `VideoUploadFormTests`. Expected: the build fails with `cannot find 'VideoUploadForm' in scope`.
- [ ] **Step 3: Implement** by moving, not rewriting, the code of `VideoUploadAPIClient` (its mime and size checks with their `AppLog` lines, `multipartParts`, the decode with the https check, `parseServerErrorMessage`) into the enum; `request(...)` builds the `URLRequest` the client builds today and adds the two optional headers. `VideoUploadAPIClient.upload` calls the form and keeps its order of checks (mime, size, authorization, URL) and its private `UploadErrorMessage`.
- [ ] **Step 4: Run** `VideoUploadFormTests`, `VideoUploadAPIClientTests` (unchanged), `UploadFeedVideoUseCaseTests`. Expected: all pass with no edit to the second and third.
- [ ] **Step 5: Commit** the files under **Files** → "Share the video upload form between the foreground client and the background uploader".

### Task 4: The durable record, its store and the body stager

**Files:**
- Create: `Marauders/Data/Upload/UploadRecord.swift`, `Marauders/Data/Upload/UploadRecordStore.swift`, `Marauders/Data/Upload/UploadBodyStager.swift`, `MaraudersTests/UploadRecordTests.swift`, `MaraudersTests/UploadRecordStoreTests.swift`, `MaraudersTests/UploadBodyStagerTests.swift`, `MaraudersTests/PrivacyManifestTests.swift`
- Modify: `PrivacyInfo.xcprivacy` (under `Marauders/`)

**Interfaces:**
- Consumes: Task 2's `UploadSnapshot`, `ClipUploadError`; cut 1's `MultipartBodyWriter`, `HTTPMultipartPart`.
- Produces:
  ```swift
  nonisolated struct UploadRecord: Codable, Equatable, Sendable {
      static let currentVersion = 1
      var version: Int; let id: UUID; let accountSubject: String; let bodyFileName: String
      let boundary: String; let byteCount: Int64; let createdAt: Date; var state: UploadRecordState
      var snapshot: UploadSnapshot { get }   // staged → uploading(0); uploading(f < 1) → uploading(f); uploading(f ≥ 1) → finishing; finished(v) → finished(v); failed(x) → failed(x.message, x.canRetry)
  }
  nonisolated enum UploadRecordState: Codable, Equatable, Sendable {
      case staged, uploading(fraction: Double, refreshedOnce: Bool), finished(FeedVideo), failed(UploadFailure)
  }
  nonisolated enum UploadFailure: Codable, Equatable, Sendable {
      case sessionEnded, unavailable, connection(String), rateLimited, rejected(String), serverError(String), interrupted, responseLost, bodyMissing
      var message: String { get }; var canRetry: Bool { get }          // the table of Global Constraints; false only for rejected and bodyMissing
  }
  nonisolated struct UploadRecordStore: Sendable {
      init(directory: URL)
      static var standardDirectory: URL { get }                         // Application Support/PendingUpload
      func prepareDirectory() throws                                    // creates it, excludes it from backup
      func records() -> [UploadRecord]                                  // deletes a record file that cannot be read or has another version
      func save(_ record: UploadRecord) throws                          // atomic
      func delete(id: UUID)                                             // the record and its body
      func deleteBody(id: UUID)                                         // the body only
      func bodyURL(id: UUID) -> URL;  func bodyExists(id: UUID) -> Bool
      func removeOrphanBodies()                                         // body files no record file names
  }
  nonisolated struct UploadBodyStager: Sendable {
      struct Staged: Equatable, Sendable { let boundary: String; let byteCount: Int64 }
      init(store: UploadRecordStore, freeSpaceMargin: Int64 = 52_428_800,
           availableBytes: @escaping @Sendable (URL) -> Int64 = UploadBodyStager.systemAvailableBytes)
      @concurrent func stage(id: UUID, parts: [HTTPMultipartPart], clipByteCount: Int64) async throws -> Staged
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `UploadRecordTests`: `aRecordRoundTripsThroughJsonInEveryState`; `aRecordHoldsNothingButItsOwnFields` (encode, read the top-level keys as a dictionary: exactly `version, id, accountSubject, bodyFileName, boundary, byteCount, createdAt, state`); `aFractionOfOneIsFinishingNotUploading` (`uploading(1.0)` is `.finishing`, `uploading(0.999)` stays `.uploading`, `staged` is `.uploading(0)`); `theFailureTextsAreExact` (every row of the table); `onlyARejectedUploadAndAMissingBodyCannotBeRetried`.
  - `UploadRecordStoreTests` (a throwaway directory per test): `aSavedRecordComesBackEqual`; `deletingRemovesTheRecordAndItsBody`; `deletingTheBodyKeepsTheRecord`; `anUnreadableOrOtherVersionRecordFileIsDeletedWhenListing`; `anOrphanBodyIsRemovedAndABodyWithARecordIsKept`; `theDirectoryIsExcludedFromBackup` (`isExcludedFromBackupKey`).
  - `UploadBodyStagerTests`: `theBodyOnDiskIsWhatTheWriterMakesForTheSamePartsAndBoundary` (write a reference with `MultipartBodyWriter.write` using the returned boundary and compare bytes); `theByteCountIsTheSizeOfTheBodyFile`; `notEnoughFreeSpaceThrowsBeforeAnythingIsWritten` (`availableBytes` returns clip + margin − 1: throws `ClipUploadError.notEnoughSpace`, the directory holds no file); `exactlyTheClipPlusTheMarginIsEnough`; `aMissingClipFileLeavesNoBodyBehind`; `theBodyFileHasNoCompleteProtection` (its `.protectionKey` is not `.complete`).
  - `PrivacyManifestTests.theManifestSaysWhyTheAppChecksFreeSpace`: read `PrivacyInfo.xcprivacy` from `Bundle.main` (the unit tests are hosted in the app) with `PropertyListSerialization`; the `NSPrivacyAccessedAPITypes` entry for `NSPrivacyAccessedAPICategoryDiskSpace` lists `E174.1`, and the two entries that are there today (`SystemBootTime` `35F9.1`, `UserDefaults` `CA92.1`) are still there.
- [ ] **Step 2: Run** the four suites. Expected: the build fails with `cannot find 'UploadRecord' in scope`.
- [ ] **Step 3: Implement.** `UploadRecordStore`: `<id lower-case>.json` and `<id lower-case>.multipart` in the directory; `prepareDirectory` creates it and sets `isExcludedFromBackup`; `JSONEncoder`/`JSONDecoder` with default settings, `.atomic` writes. `UploadBodyStager.stage`: call `store.prepareDirectory()` first (the free-space figure reads that directory), then check `availableBytes(directory) >= clipByteCount + freeSpaceMargin`, else throw `ClipUploadError.notEnoughSpace`; boundary `"marauders.boundary.\(UUID().uuidString)"`; `MultipartBodyWriter.write(parts, boundary:, to: store.bodyURL(id:))`; remove the partial file on any error; return the boundary and the file's size. `systemAvailableBytes` reads `volumeAvailableCapacityForImportantUsage` of the directory (0 when unreadable). Add the `NSPrivacyAccessedAPICategoryDiskSpace` dictionary with reason `E174.1` to `PrivacyInfo.xcprivacy`, in the file's own style.
- [ ] **Step 4: Run** the four suites. Expected: all pass.
- [ ] **Step 5: Commit** the files under **Files** → "Keep a pending upload as a durable record and a staged body file".

### Task 5: The uploader: seam, start, progress, success

**Files:**
- Create: `Marauders/Data/Upload/BackgroundUploadSession.swift`, `Marauders/Data/Upload/BackgroundClipUploader.swift`, `MaraudersTests/BackgroundClipUploaderStartTests.swift`, `MaraudersTests/Support/FakeBackgroundUploadSession.swift`, `MaraudersTests/Support/UploaderKit.swift`
- Modify: `Marauders/Domain/Auth/APIAccessTokenStore.swift` (`nonisolated enum APIAccessTokenFormat`, like its neighbours `APIAccessTokenSubject` and `APIAccessTokenExpiry`)

**Interfaces:**
- Consumes: Tasks 2 to 4; `APIAccessTokenStore.loadAccessToken() -> String?`, `APIAccessTokenSubject.subject(of:)`, `APIAccessTokenExpiry.isExpired(_:now:)`, `TokenRefreshing`, `SessionRefreshUnavailableError`.
- Produces:
  ```swift
  nonisolated enum TransportFailure: Equatable, Sendable { case cancelled, connection(String), other(String) }
  nonisolated enum UploadSessionEvent: Equatable, Sendable {
      case sentBytes(recordID: UUID, sent: Int64, expected: Int64)
      case receivedBody(recordID: UUID, data: Data)
      case completed(recordID: UUID, statusCode: Int?, failure: TransportFailure?, accessToken: String?)   // a status code wins over a failure
      case eventsFinished
  }
  nonisolated protocol BackgroundUploadSession: Sendable {
      var events: AsyncStream<UploadSessionEvent> { get }
      func submit(_ request: URLRequest, bodyFile: URL, recordID: UUID, expectedBytes: Int64)
      func pendingRecordIDs() async -> Set<UUID>
      func cancel(recordID: UUID) async
  }
  nonisolated struct UploadPolicy: Sendable {
      var maxAge: TimeInterval = 7 * 24 * 60 * 60
      var resubmitsWhileInBackground = true          // the value Task 1's D2 decides
      var responseBodyLimit = 65_536
      static let standard = UploadPolicy()
  }
  nonisolated protocol StoredUploadResolving: Sendable { func storedClip(forKey key: UUID, accessToken: String) async throws -> FeedVideo }
  actor BackgroundClipUploader {      // conforms to ClipUploading in Task 7, when retry() and reconcile() exist
      init(store: UploadRecordStore, stager: UploadBodyStager, session: any BackgroundUploadSession,
           accessTokens: any APIAccessTokenStore, refresher: any TokenRefreshing, resolver: any StoredUploadResolving,
           policy: UploadPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() },
           isAppActive: @escaping @Sendable () async -> Bool = { true })
      func setRejectionReporter(_ report: @escaping @Sendable (String) async -> Void)   // told the access token a 401 rejected for good
      func start(_ request: ClipUploadRequest) async throws
      func snapshots() -> AsyncStream<UploadSnapshot>
      func discard() async
      func apply(_ event: UploadSessionEvent) async                                   // internal: the pump and the tests call it
  }
  // Support: FakeBackgroundUploadSession (submissions, a settable pending set, cancelled ids, emit(_:)),
  //   UploaderKit (a throwaway directory, store, stager with an injectable free-space figure, fake session, SignOutSessionStorage as the token store,
  //   ScriptedRefresher, a fake resolver, a reporter log, a settable clock, request(byteCount:) making a temp mp4, record(), a SnapshotProbe that collects a stream)
  ```

- [ ] **Step 1: Write the failing tests** in `BackgroundClipUploaderStartTests` (apply events with `apply(_:)`; no pump yet):
  - `startStagesTheBodyWritesTheRecordAndSubmitsOneTask`: one submission whose request is a POST to `APIConfiguration.videoUploadURL()` with `Authorization` `Bearer <token>`, `Content-Type` `multipart/form-data; boundary=<record.boundary>` and `Idempotency-Key` equal to the record id in lower case; `bodyFile` is the store's body URL and exists with `byteCount` bytes; `expectedBytes == byteCount`; the store holds one record, `.uploading(fraction: 0, refreshedOnce: false)`, with `accountSubject` the token's `sub`.
  - `theFirstSnapshotIsIdleAndStartPublishesUploadingAtZero`; `progressIsPublishedOnlyWhenTheWholePercentChanges` (1000 bytes: 1, 5, 9 sent publish nothing; 10 publishes 1%); `allBytesSentIsFinishingNotOneHundredPercent`; `aReportThatRestartsAtZeroLowersTheFraction`; `aReportIsClampedAndAnUnknownTotalIsIgnored` (1500 of 1000 is `finishing`; expected 0 or −1 changes nothing).
  - `aSuccessWithABodyFinishesTheUploadAndDeletesItsBody`: `receivedBody` with `{"item":…}` then `completed(status: 201)` → `.finished(item)`, the record `.finished`, the body file gone.
  - `aCompletionForADiscardedRecordChangesNothing` and `anEventForAnUnknownRecordIsIgnored` (no snapshot, no file recreated).
  - `aSecondStartIsRefusedWhileOneIsStagedOrUploading` (`.alreadyUploading`); `aFinishedOrFailedRecordIsReplacedByTheNextStart`; `aSecondStartWhileTheFirstIsStillStartingIsRefused` (an expired token and a refresher held by a `SignOutGate`); `aDiscardWhileStartWaitsForTheRefreshStartsNothing` (the same held refresher: `discard()` while it is out, then the gate opens with `.refreshed`: `start` throws `ClipUploadError.unavailable`, nothing is submitted, the directory holds no file, the last snapshot is `.idle`).
  - `startWithoutAUsableTokenStagesNothing` (arguments: no token, a token that fails `APIAccessTokenFormat`, a token without `sub`: `VideoUploadAPIError.notAuthenticated`, no file); `anExpiredTokenIsTradedBeforeStaging` (`.refreshed("new")`: the submitted request carries `new`, `refresher.asked == [old]`); `aRejectedRefreshReportsTheRejectionAndStartsNothing` (`.rejected`: the reporter got the old token, `notAuthenticated`, no file); `anUnavailableRefreshStartsNothing` (`SessionRefreshUnavailableError`).
  - `notEnoughFreeSpaceStagesNothingAndSubmitsNothing`; `anUnsupportedOrOversizeClipIsRefusedBeforeAnythingIsWritten`; `discardCancelsTheTaskDeletesTheFilesAndPublishesIdle`.
- [ ] **Step 2: Run** `BackgroundClipUploaderStartTests`. Expected: the build fails with `cannot find 'BackgroundClipUploader' in scope`.
- [ ] **Step 3: Implement** `BackgroundClipUploader` and the types above; `UploadPolicy.standard.resubmitsWhileInBackground` takes Task 1's D2. `start(_:)` in this order, none of it skipped:
  1. refuse with `.alreadyUploading` while a start is running (a flag) or a record is `staged` or `uploading`; delete a `finished` or `failed` record (and cancel nothing: its task is over);
  2. `VideoUploadForm.validatedSize`; then a token that is stored, passes `APIAccessTokenFormat` and has a `sub`, else `VideoUploadAPIError.notAuthenticated`;
  3. an expired token goes through the refresher first: `.refreshed(new)` replaces the token (and the `sub` is read again), `.rejected` reports the old token and throws `notAuthenticated`, `.unavailable` throws `SessionRefreshUnavailableError`;
  4. `_ = try APIConfiguration.videoUploadURL()` so a misconfiguration fails before a file exists;
  5. `VideoUploadForm.parts`, `stager.stage` (throws `.notEnoughSpace` or the file error and leaves nothing), then `store.save` of the `staged` record (a save that throws deletes the body);
  6. build the request with `VideoUploadForm.request(authorizationHeader: "Bearer " + token, boundary:, idempotencyKey: id)`, `session.submit(...)` and, with no `await` between them, save `.uploading(fraction: 0, refreshedOnce: false)` and publish it.
  The discard rule (call 14): `discard()` bumps a counter, `start` reads it on entry and compares it after the token's refresh (3) and after `stager.stage` (5). When it moved, `start` deletes the body it staged and any record it saved, submits nothing, and throws `ClipUploadError.unavailable`.
  `snapshots()` registers a continuation (removed on termination) and yields the current snapshot first (`store.records().first?.snapshot ?? .idle`). Progress events and the success completion are applied as the tests say; the response body is buffered per record up to `policy.responseBodyLimit`. Every other completion is Task 6's: until then `apply` leaves it alone. The uploader's stored state is internal so Task 6 and Task 7's extensions can use it.
- [ ] **Step 4: Run** `BackgroundClipUploaderStartTests`, `UploadRecordTests`, `UploadRecordStoreTests`, then `sh Marauders-ios/Scripts/check-layers.sh`. Expected: all pass; the checker prints nothing.
- [ ] **Step 5: Commit** the files under **Files** → "Submit a staged clip to a background session and follow its progress".

### Task 6: Every way an upload can end

**Files:**
- Create: `Marauders/Data/Upload/BackgroundClipUploader+Completion.swift`, `MaraudersTests/BackgroundClipUploaderCompletionTests.swift`
- Modify: `Marauders/Data/Upload/BackgroundClipUploader.swift` (`apply` hands `.completed` to the extension), `MaraudersTests/Support/UploaderKit.swift` (a `GatedRefresher`: a `TokenRefreshing` that waits on a `SignOutGate`, then answers its scripted outcome)

**Interfaces:**
- Consumes: Task 5's actor, `UploadSessionEvent`, `StoredUploadResolving`, `UploadPolicy`.
- Produces: `apply(.completed(...))` settles the record by this table (the spec's table, with the builder's calls):

  | Completion | Result |
  |---|---|
  | 2xx and a body that decodes to `{item}` (https stream URL) | `finished(item)`, body deleted |
  | 2xx without a usable body | `resolver.storedClip(forKey: id, accessToken: <the event's token>)` → `finished`; a throw → `failed(responseLost)` and the body is kept |
  | 401, not yet resubmitted | ask the shared refresher to replace the event's token: `.refreshed` and (`isAppActive()` or `policy.resubmitsWhileInBackground`) → resubmit the same body and key with the new token, record `.uploading(fraction: 0, refreshedOnce: true)`; `.refreshed` but no resubmission allowed → `failed(interrupted)`; `.rejected` → `failed(sessionEnded)` and report the event's token; `.unavailable` → `failed(unavailable)` |
  | 401, already resubmitted | `failed(sessionEnded)` and report the event's token |
  | 502, 503, 504 | `failed(unavailable)`, nothing resubmitted |
  | a transport failure (`connection` or `other`) with no status | `failed(connection(text))`, nothing resubmitted |
  | 429 | `failed(rateLimited)` |
  | any other 4xx | `failed(rejected(message))`, body deleted |
  | any other status | `failed(serverError(message))`, body kept |
  | `cancelled` | ignored when the record is gone; otherwise `failed(interrupted)` |

  A `completed` that arrives for a record in `failed(interrupted)` is applied as usual (a real success upgrades it to `finished`).

- [ ] **Step 1: Write the failing tests** in `BackgroundClipUploaderCompletionTests`, one per row at least, each starting from an upload begun with `start`:
  - `a401IsHealedByARefreshAndTheSameBodyAndKeyAreSentAgain` (two submissions with the same `bodyFile` and `Idempotency-Key`, the second with the new token; record `refreshedOnce == true`, fraction 0; snapshot `.uploading(0)`); `aSecond401EndsTheSessionAndReportsTheToken` (`Your session ended. Sign in to try again.`, can retry, the reporter got the second task's token); `aRejectedRefreshEndsTheSessionAndReportsTheToken`; `anUnavailableRefreshFailsAsUnavailable`; `a401InTheBackgroundResubmitsOnlyWhenThePolicyAllows` (arguments: `isAppActive` false with `resubmitsWhileInBackground` false → `failed(interrupted)`, one submission; true → two).
  - `aGatewayErrorFailsWithTryAgainAndSubmitsNothing` (arguments 502, 503, 504); `aTransportFailureShowsItsTextAndCanBeRetried`; `aStatusCodeWinsOverATransportFailure` (201 with a `connection` failure is a success); `a429SaysTooManyUploads`; `aRejectedUploadDeletesItsBodyAndIsNotRetried` (400 with `{"error":"Video must be 100 MB or smaller"}`: that text, `canRetry: false`, body file gone); `aServerErrorKeepsTheBodyAndCanBeRetried` (500); `aCancelledTaskIsInterruptedUnlessTheRecordIsGone`.
  - `aSuccessWithoutABodyAsksTheWorkerForTheStoredClip` (the fake resolver is asked once with the record id and the event's token, and the upload ends `finished`); `aReplayThatFailsLeavesAResponseLostFailure` (the exact text; body kept; Try again allowed).
  - `aCompletionThatArrivesAfterTheInterruptedVerdictWins` (after `failed(interrupted)` a `completed(201)` with a body gives `finished`).
  - `aDiscardWhileTheRefreshIsOutLeavesNothingBehind` (a `GatedRefresher`: `apply(.completed(401))` in a task, `discard()`, open the gate with `.refreshed`: one submission only, the store empty, no snapshot after `.idle`).
  - `aSessionEndWithNoReporterStillFails` (no reporter set: the second 401 ends `failed(sessionEnded)` and nothing crashes).
- [ ] **Step 2: Run** `BackgroundClipUploaderCompletionTests`. Expected: the build fails on `GatedRefresher`, or the tests fail because `apply` ignores every completion but the success.
- [ ] **Step 3: Implement** the table in `BackgroundClipUploader+Completion.swift`. After the refresher's `await` read the record again and stop (and recreate nothing) when it is gone or no longer `uploading`; a resubmission needs the body file, else `failed(bodyMissing)`. The Worker's message comes from `VideoUploadForm.serverMessage(from:)` over the buffered body, else `Upload failed (status N)`; the buffer for a record is dropped at completion.
- [ ] **Step 4: Run** `BackgroundClipUploaderCompletionTests` and `BackgroundClipUploaderStartTests`. Expected: all pass.
- [ ] **Step 5: Commit** the files under **Files** → "Settle every way a background upload can end".

### Task 7: Launch, reconcile, Try again and the system's events

**Files:**
- Create: `Marauders/Data/Upload/BackgroundClipUploader+Launch.swift`, `MaraudersTests/BackgroundClipUploaderLaunchTests.swift`
- Modify: `Marauders/Data/Upload/BackgroundClipUploader.swift` (the `ClipUploading` conformance)

**Interfaces:**
- Consumes: Tasks 5 and 6.
- Produces (`BackgroundClipUploader` now conforms to `ClipUploading`):
  ```swift
  func launch() async                                       // starts the ordered pump once (for await event in session.events { await apply(event) }), then reconcile()
  func reconcile() async
  func retry() async
  func awaitSystemEvents(timeout: Duration = .seconds(25)) async   // the latch of call 10 under "Calls this plan makes"
  ```
  `reconcile()`: delete orphan bodies; delete a record older than `policy.maxAge` by `createdAt`; when a token is stored, delete (and cancel the task of) a record whose `accountSubject` differs from its `sub`, an unreadable `sub` counting as different; with no token stored keep the record; then by state: `staged` → mark `uploading` when `session.pendingRecordIDs()` holds its id, else submit now (no token → `failed(sessionEnded)`, no body → `failed(bodyMissing)`); `uploading` with no pending task → `failed(interrupted)` (`failed(bodyMissing)` when the body is gone); `finished` and `failed` are kept; then publish the current snapshot. After each `await` it acts on the record as it is by then (a `discard()` may have deleted it, a completion may have settled it). `retry()` works only from `failed` with `canRetry`: no token → `failed(sessionEnded)`; a token whose `sub` differs → delete the record and publish `.idle`; an expired token is traded first (as in `start`), and after that `await` the record is read again and `retry()` stops unless it is still `failed` (a `discard()` or a second `retry()` got there first); a missing body → `failed(bodyMissing)`; otherwise the same id, key, boundary and body are submitted again with `refreshedOnce` reset to false.

- [ ] **Step 1: Write the failing tests** in `BackgroundClipUploaderLaunchTests` (records are written straight into the kit's store; the kit's clock is moved, never slept):
  - `aRecordOfAnotherAccountIsDeletedAtLaunch` (record and body gone, the task cancelled, snapshot `.idle`); `anUnreadableSubjectCountsAsAnotherAccount` (a token with no `sub`); `withNoTokenStoredTheRecordIsKept`; `aRecordOfTheSameAccountIsKept`; `anOldRecordIsDeletedWithItsBody` (7 days and one second old goes; 6 days 23 hours stays); `anOrphanBodyIsDeletedAtLaunch`.
  - `aStagedRecordWithNoTaskIsSubmittedAtLaunch`; `aStagedRecordWhoseTaskExistsIsNotSubmittedAgain`; `anUploadingRecordWithNoTaskBecomesInterrupted`; `anUploadingRecordWhoseTaskExistsKeepsUploading`; `aMissingBodyBecomesBodyMissingAndCannotBeRetried`; `aFinishedRecordIsKeptUntilItIsShown`.
  - `launchStartsThePumpOnceAndAppliesEventsInOrder` (`launch()` twice, then `session.emit` of `sentBytes` and `completed`: the snapshots arrive in that order).
  - `retryReusesTheRecordIdAsTheKeyAndSendsTheSameBody` (the new submission has the old `Idempotency-Key`, boundary and `bodyFile`); `retryTradesAnExpiredTokenFirstAndResetsTheRefreshFlag`; `aDiscardWhileRetryWaitsForTheRefreshSubmitsNothing` (a `GatedRefresher` holds the trade: `retry()` in a task, `discard()`, the gate opens with `.refreshed`: no new submission, the store empty, the last snapshot `.idle`); `aSecondRetryWhileTheFirstWaitsForTheRefreshSubmitsOnce` (two `retry()` calls on the held refresher: one new submission in all); `retryDoesNothingForAFailureThatCannotBeRetried`; `retryForAnotherAccountDeletesTheRecord`.
  - `awaitSystemEventsReturnsOnceTheMarkerIsApplied` (waiting first, then `.eventsFinished`; and the marker applied before the call returns at once); `awaitSystemEventsReturnsAtTheTimeoutWhenNothingComes` (50 ms); `oneCallConsumesTheMarker` (a second call waits for its own timeout).
- [ ] **Step 2: Run** `BackgroundClipUploaderLaunchTests`. Expected: the build fails with `value of type 'BackgroundClipUploader' has no member 'launch'`.
- [ ] **Step 3: Implement** as specified. `awaitSystemEvents` suspends a continuation that `.eventsFinished` resumes and a sleeping task resumes at the timeout, whichever comes first, exactly once.
- [ ] **Step 4: Run** `BackgroundClipUploaderLaunchTests`, `BackgroundClipUploaderCompletionTests`, `BackgroundClipUploaderStartTests`, `ClipUploadUseCasesTests`. Expected: all pass.
- [ ] **Step 5: Commit** the files under **Files** → "Reconcile a pending upload at launch and let the viewer try again".

### Task 8: The real session and the replay

**Files:**
- Create: `Marauders/Data/Upload/SystemBackgroundUploadSession.swift`, `Marauders/Data/Upload/IdempotentReplayResolver.swift`, `MaraudersTests/SystemBackgroundUploadSessionTests.swift`, `MaraudersTests/IdempotentReplayResolverTests.swift`

**Interfaces:**
- Consumes: Task 5's `BackgroundUploadSession`, `UploadSessionEvent`, `StoredUploadResolving`; Task 3's `VideoUploadForm`; the existing `HTTPClient`, `URLRequest.bearerToken`.
- Produces:
  ```swift
  nonisolated final class SystemBackgroundUploadSession: NSObject, BackgroundUploadSession, URLSessionDataDelegate, @unchecked Sendable {
      static let identifier = "com.somsak.Marauders.upload"
      static func makeConfiguration(identifier: String = SystemBackgroundUploadSession.identifier) -> URLSessionConfiguration   // the flags of Global Constraints
      init(configuration: URLSessionConfiguration = SystemBackgroundUploadSession.makeConfiguration())
      static func completionEvent(recordID: UUID, response: URLResponse?, error: (any Error)?, originalRequest: URLRequest?) -> UploadSessionEvent
  }
  nonisolated struct IdempotentReplayResolver: StoredUploadResolving { init(client: any HTTPClient) }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `SystemBackgroundUploadSessionTests`: `theConfigurationHasTheSpecsFlags` (every value of Global Constraints, including the identifier); `aCompletionMapsItsStatusItsFailureAndTheTokenOfItsRequest` (arguments: a 201 response; `URLError.cancelled` → `.cancelled`; `URLError.notConnectedToInternet` → `.connection(text)`; another error → `.other(text)`; the token is the `Bearer` value of `originalRequest`); `aTaskWithoutOurRecordIdIsIgnored`; `aRealBackgroundSessionReportsProgressAndTheAnswerOverLoopback` (`.timeLimit(.minutes(1))`: a configuration with a fresh identifier, `LoopbackHTTPServer`, a 3 MB body file: `sentBytes` events, then `completed(status: 201)`; if Task 1's Part A showed the simulator does not deliver these events, drop this test and ledger a `Ruling:`).
  - `IdempotentReplayResolverTests` (cut 1's `RecordingTransport` as the `HTTPClient`): `theReplayIsABodylessPostWithTheKeyAndTheBearer` (POST to the upload URL, `Idempotency-Key` lower case, `Authorization`, no body, no multipart `Content-Type`; a 200 `{item}` answer returns the item); `aNon2xxAnswerThrowsAServerError` (a 400 `expected multipart form data`: `VideoUploadAPIError.serverError(400)`); `aBodyThatIsNotAClipThrowsInvalidResponse`.
- [ ] **Step 2: Run** the two suites. Expected: the build fails with `cannot find 'SystemBackgroundUploadSession' in scope`.
- [ ] **Step 3: Implement.** The session: `URLSession(configuration:delegate:delegateQueue: nil)` (serial, so events keep their order) with the delegate yielding into the `AsyncStream` continuation: `didSendBodyData` → `.sentBytes`, `didReceive data` → `.receivedBody`, `didCompleteWithError` → `.completed` (the status from `task.response`; `.cancelled` for `URLError.cancelled`), `urlSessionDidFinishEvents(forBackgroundURLSession:)` → `.eventsFinished`. The record id is `UUID(uuidString: task.taskDescription ?? "")`; a task without one is ignored. `submit` makes `uploadTask(with:fromFile:)`, sets `taskDescription`, the two byte-count hints of Global Constraints and resumes it; `pendingRecordIDs` and `cancel` read `allTasks`. The resolver builds `VideoUploadForm.request(authorizationHeader: "Bearer " + token, idempotencyKey: key)` with no body, sends it through `client.data(_:)`, and throws `VideoUploadAPIError.serverError(status)` for a non-2xx before decoding with `VideoUploadForm.decodeItem`.
- [ ] **Step 4: Run** the two suites and the layer checker. Expected: pass.
- [ ] **Step 5: Commit** the files under **Files** → "Add the system background session and the idempotent replay".

### Task 9: The Upload tab shows the uploader's snapshots

**Files:**
- Modify: `Marauders/Presentation/Upload/UploadVideoViewModel.swift`, `Marauders/Presentation/Upload/UploadVideoView.swift`, `Marauders/Presentation/Splash/AppRootView.swift`, `Marauders/Composition/AppDependencyContainer.swift` (the view model is built with its default idle uploader for now, and the container's `uploadRepository` parameter, property and `UploadFeedVideoUseCase` line go), `MaraudersTests/UploadVideoViewModelTests.swift`, `MaraudersTests/AppCoordinatorTests.swift`
- Create: `MaraudersTests/UploadVideoViewModelUploadTests.swift`

**Interfaces:**
- Consumes: Task 2's `ClipUploadUseCases`, `UploadSnapshot`, `FakeClipUploader`.
- Produces on `UploadVideoViewModel`:
  ```swift
  init(prepareVideo: PrepareVideoForUploadUseCase, uploads: ClipUploadUseCases = ClipUploadUseCases(uploader: IdleClipUploader()),
       locationManager: LocationManaging = CLLocationManager(), videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
       audioInspector: any ClipAudioInspecting = NoopClipAudioInspector(), holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundExecution.begin)
  struct FailedUpload: Equatable { let message: String; let canRetry: Bool }
  var isUploading: Bool { get }              // staging, or a snapshot of uploading or finishing
  var uploadProgress: Double? { get }        // nil unless isUploading; 0 while staging; 0...1
  var isFinishingUpload: Bool { get }
  var uploadProgressLabel: String? { get }   // nil, "Uploading… 42%", "Finishing…" (cut 1's texts)
  var failedUpload: FailedUpload? { get }
  func observeUploads() async                // loops over the observe use case until cancelled
  func setAppActive(_ isActive: Bool)
  func retryUpload() async
  func chooseAnotherVideo() async            // discards the upload, then resetPickedFile()
  ```

- [ ] **Step 1: Write the failing tests** in `UploadVideoViewModelUploadTests` (a `FakeClipUploader` through `ClipUploadUseCases`; `makeViewModel` in `UploadVideoViewModelTests` takes a `FakeClipUploader` instead of a repository):
  - `theRequestCarriesTheSpeechCheckTheCaptionAndNoLanguage` (the old `uploadSendsTheSpeechCheckButNeverALanguage`, now on `started`); `startingClearsTheFormAndDeletesTheExportedFile` (after `start` returns: `uploadFileURL == nil`, `caption == ""`, `audioAssessment == nil`, the temp file gone); `theButtonStaysDisabledBetweenStartAndTheFirstSnapshot` (`isUploading` stays true after `start` returns, before the uploader's first snapshot); `aStartThatFailsShowsItsMessageAndKeepsTheFile`; `aSecondTapWhileUploadingStartsNothing` (`started.count == 1`).
  - Progress (the cut 1 tests, ported to snapshots): `theLabelRoundsDownAndEndsWithTheUpload`; `allBytesSentShowsFinishingNotOneHundredPercent`; `aFractionOutsideTheRangeIsClamped`; `aFractionThatIsNotANumberChangesNothing`.
  - Safety net: `theSafetyNetCoversStagingAndIsReleasedWhenItEnds` (the hold begins at the tap, is released once `start` returns), `...WhenStartFails`, `...WhenTheTapIsCancelled`; `aTapThatStartsNothingHoldsNoTask`.
  - `aFailureShowsItsMessageAndTheButtonsItAllows` (`failedUpload` and `statusMessage` carry the message, `isSuccess == false`; `canRetry: false` leaves only Choose another video); `tryAgainAsksTheUploaderToRetry`; `chooseAnotherVideoDiscardsTheUploadAndResetsTheForm`; `pickingAnotherVideoDiscardsAFailedUpload`.
  - `aFinishedUploadIsReportedOnceWhenTheAppIsActive` (`setAppActive(true)`, a `.finished(video)` snapshot: `onUploaded` runs once with the video, the uploader's `discards == 1`, `statusMessage == "Upload complete — opening feed"`, a second identical snapshot reports nothing); `aFinishedUploadWaitsForTheAppToBecomeActive` (nothing while inactive; reported once on `setAppActive(true)`).
  - Rewrite or delete the tests of `UploadVideoViewModelTests` that went through the old `upload()` (`uploadSendsTheSpeechCheckButNeverALanguage`, `canUploadIsFalseWhileUploading`, `uploadSuccessMarksSuccessAndRequestsFeedReload`, `uploadFailureSurfacesErrorAndKeepsFile`, and cut 1's thirteen from `theBarStartsAtZeroWhenTheUploadStarts` to `aTapThatStartsNothingHoldsNoTask`) and the doubles only they used (`AssessmentRecordingRepository`, `HeldUploadRepository`, `SleepingUploadRepository`), and fix the seven construction sites (two in `UploadVideoViewModelTests`, five in `AppCoordinatorTests`).
- [ ] **Step 2: Run** `UploadVideoViewModelUploadTests`, `UploadVideoViewModelTests`, `AppCoordinatorTests`. Expected: the build fails with `extra argument 'uploads' in call`.
- [ ] **Step 3: Implement.** `upload()` keeps its two guards, holds the safety net (`holdAwake("Upload video")`), sets `isStagingUpload`, and calls `uploads.start.execute(ClipUploadRequest(...))`; on success it sets the snapshot to `.uploading(fraction: 0)` itself when it is still `.idle`, clears `isStagingUpload`, deletes the exported file (`discardExportStagingFile()`), clears `audioAssessment` and `caption`; on an error it shows `error.localizedDescription` and keeps the file. `observeUploads()` applies each snapshot: a fraction that is NaN is ignored and others are clamped to 0...1; `.failed` sets `statusMessage` and `isSuccess = false`; `.uploading` and `.finishing` clear a failure message. `reportFinishedUploadIfNeeded()` (from a `.finished` snapshot and from `setAppActive(true)`) acts only when the app is active, a `.finished(video)` is current and `reportedFinishedID != video.id`: set the id, `isSuccess = true`, the status text, `await uploads.discard.execute()`, then `await onUploaded?(video)`. `prepare(sourceURL:)` discards a failed upload first. The view: under the Status section a failed upload gets `Try again` (`upload.retry`, only when `canRetry`) and `Choose another video` (`upload.chooseAnother`) buttons next to the `CopyableStatusBanner`; the picker resets (`pickerItem = nil`) when `uploadFileURL` becomes nil while `isUploading || isSuccess`. `AppRootView` adds `.task { await container.uploadViewModel.observeUploads() }` and `@Environment(\.scenePhase)` with `.onChange(of: scenePhase, initial: true) { _, phase in container.uploadViewModel.setAppActive(phase == .active) }`.
- [ ] **Step 4: Run** the three suites, then the whole unit target and the layer checker. Expected: all pass, and no `uploadVideo:` or `UploadFeedVideoUseCase` is left in `UploadVideoViewModel` or the container.
- [ ] **Step 5: Commit** the files under **Files** → "Show the Upload tab from the uploader's snapshots".

### Task 10: Sign-out, sign-in, launch and the relaunch route

**Files:**
- Modify: `Marauders/Presentation/Auth/AuthViewModel.swift`, `Marauders/Composition/AppDependencyContainer.swift`, `Marauders/App/MaraudersApp.swift`, `MaraudersTests/AppDependencyContainerWiringTests.swift`
- Create: `MaraudersTests/AuthViewModelUploadHooksTests.swift`; `Marauders/App/MaraudersAppDelegate.swift` only for route B

**Interfaces:**
- Consumes: Tasks 7 to 9.
- Produces:
  ```swift
  // AuthViewModel
  @ObservationIgnored var discardUploadOnSignOut: DiscardClipUploadUseCase?
  @ObservationIgnored var checkUploadOnSignIn: ReconcileClipUploadUseCase?
  @ObservationIgnored var uploadHookTimeout: Duration = .seconds(3)
  // AppDependencyContainer
  static let clipUploader: BackgroundClipUploader      // built once per process, before any container (mark it nonisolated if the compiler asks)
  ```

- [ ] **Step 1: Write the failing tests.** `AuthViewModelUploadHooksTests` (the harness of `SignOutLocationSharingTests`, a `FakeClipUploader` through `ClipUploadUseCases`): `signingOutDiscardsTheUploadBeforeTheSessionIsCleared` (the fake's `onDiscard` reads the storage: the token is still there; `discards == 1`); `signingOutDiscardsTheUploadEvenWhenNotSignedIn`; `aSessionEndedByRejectionKeepsTheUpload` (`handleRejectedAccessToken` discards nothing); `aDiscardThatNeverReturnsDoesNotHoldTheSignOutBack` (`discardGate` closed, `uploadHookTimeout = .milliseconds(50)`: `signOut()` returns and the session is cleared); `signingInChecksTheStoredUploadBeforeTheViewerIsSignedIn` (with `ScriptedAuthAPI` succeeding: `reconciles == 1` and `isSignedIn` was still false when it ran); `aFailedSignInChecksNothing`. `AppDependencyContainerWiringTests.theAuthViewModelIsGivenBothUploadHooks`.
- [ ] **Step 2: Run** `AuthViewModelUploadHooksTests`, `AppDependencyContainerWiringTests`. Expected: the build fails with `value of type 'AuthViewModel' has no member 'discardUploadOnSignOut'`.
- [ ] **Step 3: Implement.**
  - `AuthViewModel.signOut()`: after `if isSignedIn { await tellTheWorkerTheSessionIsEnding() }` and before `clearStoredSession()`, run the discard hook through `TimeBoundedCall.run(timeout: uploadHookTimeout)` (log a warning on `.failed` or `.timedOut`). `completeSignIn` and the Debug `signInAsDevUser`: after the tokens are stored and before `isSignedIn = true`, run the check hook the same way.
  - `AppDependencyContainer.clipUploader`: `UploadRecordStore(directory: UploadRecordStore.standardDirectory)`, an `UploadBodyStager` on it, `SystemBackgroundUploadSession()`, `KeychainAPIAccessTokenStore()`, the shared `tokenRefresher`, `IdempotentReplayResolver(client: APITransportComposition.quiet(base: URLSessionHTTPClient(), refresher: tokenRefresher))`, `UploadPolicy(resubmitsWhileInBackground: <D2>)` and `isAppActive: { await MainActor.run { UIApplication.shared.applicationState == .active } }`. The container builds `ClipUploadUseCases(uploader: AppRuntimeConfiguration.isUITesting ? IdleClipUploader() : Self.clipUploader)` for the view model and both hooks, and sets the reporter: `Task { await Self.clipUploader.setRejectionReporter { token in await MainActor.run { authViewModel.handleRejectedAccessToken(token) } } }` (weak capture), not under UI tests.
  - `MaraudersApp.init`, after the location monitor and unless `AppRuntimeConfiguration.isUITesting`: `let uploader = AppDependencyContainer.clipUploader` (this creates the session now) and `Task { await uploader.launch() }`.
  - The relaunch route, by D3. **Variant A:** `.backgroundTask(.urlSession(SystemBackgroundUploadSession.identifier)) { await AppDependencyContainer.clipUploader.awaitSystemEvents() }` on the `WindowGroup` scene. **Variant B:** `MaraudersAppDelegate` (`NSObject, UIApplicationDelegate`) whose `application(_:handleEventsForBackgroundURLSession:completionHandler:)` ignores other identifiers and otherwise awaits `awaitSystemEvents()` and then calls the completion handler on the main thread, attached with `@UIApplicationDelegateAdaptor(MaraudersAppDelegate.self)`. Write only the chosen variant.
- [ ] **Step 4: Run** the two suites, then the whole unit target, `sh Marauders-ios/Scripts/check-layers.sh` and `xcrun swift-format lint` over the touched files. Expected: all pass; the app launches on the simulator with no crash (the unit run hosts it) and `AppLog` shows the `upload.bg` launch line.
- [ ] **Step 5: Commit** the files under **Files** → "Wire the background uploader into sign-out, sign-in and launch".

### Task 11: Documentation and whole-branch verification

**Files:**
- Create: `docs/adr/008-background-upload.md`
- Modify: `ARCHITECTURE.md`, `docs/adr/README.md`

- [ ] **Step 1: Update `ARCHITECTURE.md`** (find each place by its heading or text, not by line number: the Worker plan edits other lines of the same file): "Upload path (client)": the body is staged to `Application Support/PendingUpload` and sent by a background `URLSession` that survives leaving the app and an app ended by the system (not a swipe-away), with one record, the idempotency key, the failure and Try again states, the 7-day and account rules; the "MVVM flow (upload)" diagram: `UploadVideoViewModel → ClipUploadUseCases → ClipUploading → BackgroundClipUploader → BackgroundUploadSession`; the `/v1/videos` row of the API table (the header the app sends); remove "Not implemented: automatic retry on upload" and say what is retried by hand; "iOS — upload file lifecycle (staging)": the body no longer lives in `NSTemporaryDirectory()`, its life cycle and where it is deleted; the folder tree (`Data/Upload/`).
- [ ] **Step 2: Write `docs/adr/008-background-upload.md`** in ADR 007's format (Title, Status, Date, Scope, Context, Decision, Alternatives, Consequences, References; English): the spike's evidence (the note), the decision (approach C) and approaches A (the 30 s safety net, cut 1), B (`BGContinuedProcessingTask`, its locked-phone report) and D (resumable upload); consequences: a swipe-away still ends the upload, a refresh inside a background wake can be cut off (ADR 007 lists it as not covered), the Worker's memory limit is unmeasured, the lost-answer-after-commit limit of the Worker plan, the old in-process video path left unwired. Add its row to `docs/adr/README.md` in the table's format.
- [ ] **Step 3: Check the branch.** `git diff --stat main...HEAD` lists only the files this plan names; `git diff main...HEAD --stat -- Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` prints nothing; `grep -rn "UploadFeedVideoUseCase" Marauders-ios/Marauders/Presentation Marauders-ios/Marauders/Composition` prints nothing.
- [ ] **Step 4: Run the whole unit target** (`-only-testing:MaraudersTests`). Expected: `** TEST SUCCEEDED **`; write down the total (1061 plus this work's) and the suite count.
- [ ] **Step 5: Run the checkers:** `sh Marauders-ios/Scripts/check-layers.sh` and `xcrun swift-format lint` over every Swift file the branch touched print nothing; `Scripts/layer-exceptions.txt` is unchanged.
- [ ] **Step 6: Run the unsigned Release archive.** Expected: `** ARCHIVE SUCCEEDED **` and no error lines.
- [ ] **Step 7: Run the UI target once**, detached. Expected: 51 of 52, the red being the known simulator-only comment-language test.
- [ ] **Step 8: Commit** the files under **Files** → "Document the background upload and its decision record".

## After the last task (the owner's calls, not tasks)

- **Order of rollout** (the spec): the Worker plan's migration 023, then the Worker deploy, then the app. Merge the Worker branch first; merge this branch into `main` next (its own yes, after the `git merge-tree` check of Global Constraints), re-run the unit target on the merged tree, and the UI target and the Release archive too when that tree is not the branch's tree. Push is a separate yes.
- **A TestFlight build** (Jenkins "Build Now" is the owner's; a push builds nothing), only after the Worker is deployed.
- **The phone checks** of the spec's Verification, only when the owner asks, each upload a real clip to delete from Profile afterwards: Home during an upload; lock the phone; Airplane mode on and off; end the process with `devicectl` (not a swipe) and relaunch, and see the clip arrive; swipe the app away and see "The upload was interrupted. Try again."; a 401 healed through `DEBUG_INVALIDATE_ACCESS_TOKEN`; and, with the Worker, the same body sent twice under one key (201, then 200 with the same clip). Whether to test against the production Worker is the owner's call.
- **Removing the old in-process video path** (`UploadFeedVideoUseCase`, `VideoUploadRepository`, `DefaultVideoUploadRepository`, `VideoUploadAPIClient.upload` and their tests) and **removing the finished worktrees**: each a separate yes.
