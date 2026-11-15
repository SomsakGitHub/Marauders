# Upload resilience: design

Date: 2026-11-15
Status: approved by the owner on 2026-11-15. Nothing in this document has been built. Cut 1 is planned in `docs/superpowers/plans/2026-11-15-upload-resilience-cut-1.md`; cut 2 gets its own plan after cut 1 has landed.
Topic: Networking. Gap 1 of the review of 2026-11-15: a video upload has no protection when the viewer leaves the app. The owner chose approach C, built in two cuts, on 2026-11-15.

## Intent

A viewer who taps Upload may switch to another app, lock the phone or lose the network for a while. The clip should still
reach the Worker, and the app should show the result when the viewer is back.

Today the upload is one foreground `URLSession` request. iOS suspends an app a few seconds after it leaves the screen, so the
connection is expected to drop (expected from how iOS behaves; not measured on a device). The viewer sees an error and
starts again from the first byte. Starting again can also leave a duplicate clip, because the Worker cannot tell a repeated
upload from a new one.

## Goals

- After Upload is tapped the clip arrives although the viewer leaves the app, locks the phone or is offline for a while. (cut 2)
- It also arrives when iOS ends the app process during the transfer. (cut 2)
- A retry never creates a second clip. (cut 2, Worker)
- The viewer sees how far the upload has got. (cut 1)
- A clip is never read whole into memory. (cut 1)
- Whatever happens, the Upload tab ends in a state the viewer can act on: done, or failed with a Try again. Never a spinner
  that does not end. (cut 2)
- The avatar upload, the dubbed-audio upload and every app build that is already installed keep working unchanged.

## Non-goals

- Surviving a swipe-away from the app switcher. iOS cancels an app's background transfers then and nothing prevents it. The
  next launch shows "interrupted" with a Try again.
- Leaving the app during "Preparing video…" (the 720p export). The export still needs the app on screen.
- Resumable or chunked upload (approach D), several queued uploads, a Wi-Fi-only switch, a Live Activity, a local
  notification when the upload is done, deduplication by clip content.
- Changing the export preset, the 100 MB cap, or how the Worker buffers a body (see "Risks to measure early").
- `BGContinuedProcessingTask` (approach B).
- Resubmitting an upload from a background wake, except after a healed 401. Apple's documentation, as the reviewer of this
  design read it (`URLSessionConfiguration.isDiscretionary` and "Downloading files in the background"; the builder
  confirms), treats a task created while the app is in the background as discretionary, with a start delay that grows each
  time the app is relaunched and resets when the viewer brings the app to the foreground. Such a retry could start hours
  late, so the viewer taps Try again instead.

## Anti-goals (a failure even if the happy path works)

- A duplicate clip in the feed from a retry or a lost response.
- A clip, caption or location left on disk after the upload ended or the viewer signed out. (The one exception is a
  session the Worker ended: see "Sign-out and account change".)
- A progress bar at 100% before the Worker has answered.
- Upload code that signs the viewer out, or a second refresher that races the shared one (a refresh token is single use,
  ADR 007).
- A background launch that needs the UI or the dependency container to finish an upload.

## How it works today

App (`Marauders-ios/Marauders/`):

- The clip comes from `PhotosPicker`. `VideoExportService` exports 720p H.264 into `NSTemporaryDirectory()` as soon as it
  is picked. There is no length cap, only the 100 MB cap on the exported file (`VideoUploadAPIClient.maxUploadBytes`).
- `Presentation/Upload/UploadVideoViewModel.swift` is created once by `AppDependencyContainer` and lives as long as the
  process, so a tab switch is safe. `upload()` sets `isUploading`, awaits `UploadFeedVideoUseCase`, on success discards the
  export file and calls `onUploaded` (`AppCoordinator` reloads the feed, focuses the new clip and shows the Feed tab), on
  failure keeps the file and shows the error. There is no progress and no background time.
- `Data/API/VideoUploadAPIClient.swift` reads the whole clip with `Data(contentsOf:)`, builds the multipart parts and calls
  `HTTPClient.upload`. `URLSessionHTTPClient` (`Data/API/HTTPClient.swift`) writes the multipart body to a temp file and
  sends it with `session.upload(for:fromFile:)` on `URLSession.shared`; the request timeout is 300 s.
- The transport an upload goes through: rejected-session reporter, then `TokenRefreshingHTTPClient` (replays a 401 once
  with the same parts), then `RetryingHTTPClient` (never retries an upload), then `URLSessionHTTPClient`.
- Five types conform to `HTTPClient` in the app (the base client, the three wrappers, `UITestRejectingHTTPClient`) and five
  test doubles. `UserProfileAPIClient` uploads the avatar through the same call.
- `AppDependencyContainer` has two statics built before any container exists: `tokenRefresher` (the one refresher of the
  process) and `backgroundLocationMonitor`, which `MaraudersApp.init` starts unless UI tests run, because iOS may launch the
  app in the background with no UI. There is no AppDelegate (scene phase only). The Info.plist is generated
  (`GENERATE_INFOPLIST_FILE = YES`, no `UIBackgroundModes`).
- `AuthViewModel.signOut()` runs hooks that the container sets (`stopSharingOnSignOut`) before it clears the stored session.
- `BackgroundLocationMonitor.swift` holds a private `beginBackgroundTask` helper.
- Layer rules (`Scripts/check-layers.sh`): Domain imports Foundation only; Data does not import SwiftUI or name Presentation
  types; Presentation names no Data types; a `*View.swift` names no use case. Nine exceptions are accepted; new code adds none.

Worker (`backend/`):

- `POST /v1/videos` (`src/index.ts`): bearer auth, then the `upload` rate limit (10 per 60 s per user, shared with the avatar
  upload), then `handleVideoUpload` (`src/routes/upload.ts`).
- `handleVideoUpload` buffers the body: `request.formData()`, `file.arrayBuffer()`, a fast-start pass for MP4 up to 80 MB,
  the R2 put under `videos/<uuid>.<ext>`, `insertFeedVideo`. It deletes the R2 object when the insert fails and answers 201
  `{ item }`.
- `feed_videos` has no column that identifies the client's upload, so a repeated upload is a new clip.
- `scripts/migrate.mjs` lists every migration by name and replays all of them on each run (so each must be idempotent; it
  splits on `;` before it strips `--` comments, so no `;` inside a comment). Worker tests are bundled with esbuild by
  `scripts/test-*.mjs` and run on the fake Neon driver in `test/fakes/neon.ts`.

## Approaches

The owner picked C on 2026-11-15.

**A. `beginBackgroundTask`.** iOS grants about 30 s (not guaranteed). Small, no Worker change, testable on the simulator. It
only saves a clip that finishes inside the grace period. Kept as a safety net (cut 1, and around the short steps of cut 2).

**B. `BGContinuedProcessingTask` (iOS 26+).** Not chosen. The Apple Developer Forums document a bug in which the task pauses
or expires when the screen is truly locked: Apple's DTS engineer called it a bug and expected a fix in iOS 26.1, a developer
still reported it on iOS 26.1 and 26.2 beta 3 with an S3 upload, and nothing was found for iOS 27. Cancel by the viewer and
expiry by the system cannot be told apart (Apple: an oversight), on some devices the task never starts, and it can only be
proven on a phone. Locking the phone is one of the commonest ways to leave an app.

**C. Background `URLSession` file upload (chosen).** iOS's transfer daemon sends the file for the app, through suspension and
through the system ending the app, and wakes the app with the result. Costs: a delegate API (no async/await), files only (the
app already uploads from a file), a durable body file and a record of the upload, a 401 handled by hand, an idempotency key at
the Worker, and a scheduler that may defer background transfers (see "Risks to measure early").

**D. Resumable or multipart upload through R2.** The most robust, and the only one that also fixes the Worker's memory use.
It rewrites the Worker and the client. Not now.

## Delivery: two cuts

Cut 1 ships on its own and helps by itself. Cut 2 is planned after cut 1 has landed and its device results are in, so each
gets its own implementation plan.

## Design: cut 1 (no Worker change)

1. **Stream the clip from disk.** `HTTPMultipartPart` gets a file-backed case (for example
   `.fileAt(name:filename:mimeType:url:)`); `URLSessionHTTPClient.writeMultipartBody` copies it in chunks (suggested 1 MiB,
   `FileHandle.read(upToCount:)`). The `Data` case stays for the avatar. `VideoUploadAPIClient` uses the file-backed case and
   drops `Data(contentsOf:)`; its size check on the file's attributes stays. Peak memory no longer depends on the clip size.
2. **Progress.** `HTTPClient` gets a second upload requirement taking a `progress: (@Sendable (Double) -> Void)?` and a
   default in a protocol extension that calls the two-argument form, so the five test doubles and
   `UITestRejectingHTTPClient` need no change. `URLSessionHTTPClient` implements it with a task delegate on
   `session.upload(for:fromFile:delegate:)` (`didSendBodyData`). The three wrappers forward it. A replay after a 401 starts
   again at 0. Domain gets a progress callback on `VideoUploadRepository.upload` and `UploadFeedVideoUseCase.execute`. The
   view model publishes `uploadProgress: Double?` and the view shows a determinate bar ("Uploading… 42%"). When every byte is
   sent and no answer has come, the bar becomes indeterminate with "Finishing…", because the Worker still does the fast-start
   pass, the R2 put and the insert.
3. **Safety net (A).** A small helper in Presentation holds `UIApplication.beginBackgroundTask` from the start of the request
   until it ends, behind a protocol or closure the view model takes, so a test can fake it. `BackgroundLocationMonitor` uses the
   same helper instead of its private copy. The expiration handler ends the task and does nothing else: the connection is
   then expected to fail and the viewer sees the existing error.

## Design: cut 2, the app

**Flow.** Tap Upload: a use case first trades an access token whose `exp` has passed (through the shared refresher, see the
401 row), then stages a durable body file, writes the record, submits a background task and returns. From
then on the view model only observes the record. The exported clip in the temp folder is deleted once the body is staged.

**Staging.** The multipart body is written (same chunked writer as cut 1) to
`Application Support/PendingUpload/<id>.multipart`, excluded from backup, with the default file protection (readable after the
first unlock: do not use `.complete`, which would block a transfer while the phone is locked). The boundary string is kept in
the record, because a later submission needs the same `Content-Type`. Staging runs inside the cut 1 safety net. Not enough
free space (less than the body size plus a margin) fails before anything is written, with a clear message.

**One slot.** One record at a time, as the Upload tab allows one upload at a time today. Starting a new upload replaces a
finished or failed record.

**The record** (a small JSON file next to the body; versioned): the id (a UUID made when Upload is tapped and kept for every
submission of this body: it is the idempotency key), the `sub` of the access token it was started with
(`APIAccessTokenSubject`), the body file name and boundary, the clip's byte count, the creation time, and
the state:

```
staged ──submit──▶ uploading ──2xx──▶ finished(item) ──viewer sees it──▶ (record deleted)
                      │  ▲
              failure │  │ Try again (same body, same key), or one resubmit after a healed 401
                      ▼  │
                    failed(reason, canRetry)
```

Any state goes to "deleted" on Discard or sign-out. A terminal state older than 7 days is deleted at the next launch.

**The uploader** (Data layer; one object per process, like the location monitor; built as a static before any container, and
started by `MaraudersApp.init` unless `AppRuntimeConfiguration.isUITesting`). It owns:

- a `URLSession` with `URLSessionConfiguration.background(withIdentifier: "com.somsak.Marauders.upload")`, a delegate,
  `isDiscretionary = false` (the viewer asked for it), cellular and Low Data Mode allowed, `timeoutIntervalForResource` of
  24 hours, the total ceiling for one upload, so a task that cannot finish ends as a failure instead of an upload that never ends;
- the request: `POST` to `APIConfiguration.videoUploadURL()`, `Authorization: Bearer <stored access token>`,
  `Content-Type: multipart/form-data; boundary=<recorded>`, `Idempotency-Key: <record id>`, and
  `uploadTask(with:fromFile:)` on the staged body (the only upload form a background session accepts). `taskDescription` is
  the record id, so a task found after a relaunch can be matched to its record. `countOfBytesClientExpectsToSend` and
  `...ToReceive` are set so the system can plan. The validation, URL and field names are shared with `VideoUploadAPIClient`
  (extract them once; do not copy them). No Info.plist entry is expected to be needed, because a background `URLSession`
  does not need a background mode; the builder confirms that in Apple's documentation;
- the delegate events, applied to the record in order before the system is told it may suspend the app: bytes sent
  (progress, throttled), the response body (kept up to 64 KB), completion.

**On completion.**

| Outcome | Action |
|---|---|
| 2xx and a decodable `{ item }` with an https stream URL | `finished(item)`, body deleted |
| 401 | Ask the shared `AppDependencyContainer.tokenRefresher` to replace the token the task carried. A new token: resubmit the same body and key, once per submission (a second 401 is a failure). The token is checked when Upload is tapped, in the foreground, and traded first if its `exp` has passed, so a 401 that reaches a background wake is rare. A refusal or an answer without a verdict: `failed(sessionEnded)` / `failed(unavailable)`, Try again enabled. The uploader never signs anyone out and never clears a store; the container, when it exists, reports the rejection to `AuthViewModel` as it does for every other client |
| 502, 503, 504, or a `URLError` (connection lost, timed out, offline, DNS, host not reachable) that reaches the app | `failed(reason)` with Try again. No automatic resubmission (see Non-goals). What the system retries by itself before it reports anything is noted in the spike. The 24 h resource timeout is the total ceiling for the upload, and its "timed out" is a failure, not a retry |
| 429 | `failed("Too many uploads, try again in a minute")`, Try again, no automatic retry |
| Any other 4xx or 5xx | `failed(the Worker's message)`; a 4xx other than 429 cannot succeed with the same body, so the body is deleted and only "Choose another video" is offered |
| Cancelled | The record is deleted when the viewer discarded it; otherwise `failed(interrupted)` |

A refresh inside a background wake can be cut off by suspension, which ADR 007 lists as not covered (the Worker would read
the repeated token as reuse and end the family). The background location monitor accepts the same risk, and the check of the
token when Upload is tapped keeps it rare.

**Launch and relaunch.** At launch the uploader recreates the session with the same identifier (iOS delivers pending events
only to a session that exists) and runs `reconcile`:

- a `finished` record is kept until the view model has shown it;
- an `uploading` record whose task `getAllTasks` no longer lists was cancelled or lost (a swipe-away): `failed(interrupted)`,
  Try again enabled while the body file exists;
- a `staged` record (the process ended between staging and submitting): submit it now;
- a body file without a record, and a record older than 7 days: deleted;
- a record whose `sub` differs from the stored token's, when a token is stored: deleted, so one viewer never resumes
  another's upload. With no token stored (the session ended) the record is kept, and the same check runs again whenever a
  sign-in completes (the container tells the uploader), so the same account can finish and another account never sees it.

When iOS relaunches the app in the background to hand over events, the scene's `.backgroundTask(.urlSession("<id>"))` runs
the work (the app has no AppDelegate). The builder confirms the exact lifetime rules of that API in Apple's documentation
first; if it cannot do what is needed, a `UIApplicationDelegateAdaptor` with
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` is the fallback. Either way the uploader finishes
without the container or any view.

**Domain and view model.** Domain gets a snapshot type (`uploading(fraction)`, `finishing`, `finished(FeedVideo)`,
`failed(message, canRetry)`), a protocol over the uploader that can start, observe (an `AsyncStream` whose first value is
the current snapshot, so a relaunch shows the right state at once), retry and discard, and one use case for each, in the
project's style. `UploadVideoViewModel` keeps preparing, location and caption; the upload part becomes a view of the
snapshot: the progress row, the existing success text, and a failure banner with Try again (when `canRetry`) and Choose
another video. A `finished` snapshot is reported to `onUploaded` exactly once, when the app is active, whether the upload
ended while the viewer watched or while the app was closed. Under UI tests the view model gets an uploader that never
starts anything.

**Sign-out and account change.** `AuthViewModel` gets a hook set by the container, like `stopSharingOnSignOut`: Discard
cancels the task and deletes the record and the body, with no call to the Worker. A session that ends without a sign-out (a
rejected token, a refused refresh) keeps the record, for 7 days at most, so the same account can finish after signing in
again; the `sub` check above, run again at every sign-in, deletes it when another account signs in. That is a choice: the
unsent clip stays in the app's own sandbox on a phone that looks signed out.

**Privacy.** The body holds the clip, the caption and the coordinates, so: Application Support, excluded from backup,
deleted in every terminal state and at sign-out, never logged. `AppLog` lines (`upload.bg`) carry the record id and the
state, never a token.

## Design: cut 2, the Worker

- **Migration `backend/sql/023_feed_video_upload_key.sql`**, added to `scripts/migrate.mjs`:

  ```sql
  ALTER TABLE feed_videos ADD COLUMN IF NOT EXISTS upload_key UUID;
  CREATE UNIQUE INDEX IF NOT EXISTS feed_videos_owner_upload_key_uidx
      ON feed_videos (owner_user_id, upload_key) WHERE upload_key IS NOT NULL;
  ```

- **The header.** `handleVideoUpload` reads `Idempotency-Key` first, before `request.formData()`. Missing: the path is
  exactly today's (old app builds). Not a UUID: 400 `Idempotency-Key must be a UUID`. A UUID is lower-cased.
- **A key that is already stored for this user** answers 200 with the stored clip, in the same `{ item }` shape, without
  reading the body and without touching R2. The key is scoped to the owner: another user's identical key is just a new key.
- **A new key**: the work is unchanged, and `insertFeedVideo` takes the key. The insert is
  `INSERT … ON CONFLICT (owner_user_id, upload_key) WHERE upload_key IS NOT NULL DO NOTHING RETURNING …`. When it returns no
  row, two requests with the same key raced: the R2 object this request just wrote is deleted and the stored clip is
  answered with 200.
- **New clip: 201 as today. Replay: 200.** The app treats every 2xx as success.
- The rate limit still runs before the handler, so a replay counts against the 10 per 60 s like any upload.
- **Tests** (`test/uploadIdempotency.test.ts`, `scripts/test-upload-idempotency.mjs`, `npm run test:upload-idempotency`, on
  the fake Neon driver and a fake `VIDEOS` bucket): no header behaves as today; a bad header is 400; a stored key answers 200
  without reading the body or touching the bucket; a new key answers 201 and the insert carries the key; the conflict race
  deletes the new object and answers 200 with the stored clip; another user's key does not match. The two SQL statements are
  also run once against a real Postgres (a throwaway PGlite or a local database) before the migration is run live, because the
  fake driver checks statement shapes, not SQL.

## Verification

- **Unit tests on the simulator** (the owner's rule): the chunked writer, progress through the wrappers, the view model, the
  safety net, and for cut 2 the state machine driven through a seam over the background session (a protocol with a fake;
  the delegate events are plain method calls), including each row of the completion table, `reconcile`, the `sub` check,
  and sign-out. The Worker tests above.
- **On the phone**, only when the owner says so (the owner's iPhone on iOS 27; the observation method of the token-refresh test,
  `devicectl` plus a JSON `wrangler tail`, works). Cut 1: leave the app for 5 s and for 60 s during an upload and lock the phone; the short absence is expected to finish and the long one to fail with the existing error.
  Cut 2: Home during an upload; lock the phone; Airplane mode on and off; end the process with `devicectl` (not a swipe) and
  relaunch; swipe the app away and see "interrupted"; a 401 with `DEBUG_INVALIDATE_ACCESS_TOKEN` before the upload; the same
  body sent twice with one key (Worker side). Each device upload creates a real clip in the live feed: use a short clip and
  delete it from the Profile tab afterwards. Whether to test against the production Worker is the owner's call.
- `xcodebuild` unit and UI suites and the Release archive check on the merged tree of each cut, as for earlier work.

## Rollout, order and rollback

- Cut 1 is app-only: merge, then a TestFlight build whenever the owner starts one (Jenkins is manual).
- Cut 2: migration 023, then the Worker deploy, then the app. The Worker change is backwards compatible, so builds already in
  use keep working. Each of merge, migration and deploy is asked separately, as always.
- Rollback: `wrangler rollback` to the version in service before (961faf99 today); the column is harmless and
  `ALTER TABLE feed_videos DROP COLUMN upload_key` removes it and its index.

## Documentation to update

`ARCHITECTURE.md` (the upload path, the MVVM upload sequence, the `/v1/videos` row with the header and the 200 replay), a new
`docs/adr/008-background-upload.md` with its row in `docs/adr/README.md`, and the pre-deploy test list in
`deployment/README.md` (`test:upload-idempotency`).

## Risks to measure early

- **The system scheduler.** One Apple forum report (20 GB+ and many files) describes background uploads deferred for hours
  or days under an energy or data budget, fine on external power; Apple calls the policy an implementation detail. A single
  clip of 30 to 100 MB is unlikely to meet it, but nothing here proves that. The first task of cut 2 is a throwaway spike on
  the phone: one clip through a background session in the foreground, in the background and locked, on battery, noting
  start delay and duration, and whether a dropped connection (Airplane mode on and off) is resumed by the system or reported
  as a failure. Also one task created from a background wake, which is what a healed 401 does: if it takes
  longer than 2 minutes to start, the 401 row stops resubmitting from a background wake as well and leaves
  `failed(canRetry)`. If a foreground task is deferred, cut 2 changes (for example, the foreground keeps the cut 1 path while the app
  is on screen).
- **Relaunch through SwiftUI.** The `.backgroundTask(.urlSession)` route, with no AppDelegate, is untried here.
- **The Worker's memory.** It buffers a body two or three times over (`formData`, `arrayBuffer`, the fast-start copy) in an
  isolate with 128 MB; the client's 100 MB cap may be above what it can take. Not measured, not made worse by this work
  (the same bytes arrive), and a viewer who taps Try again on a clip the Worker cannot hold meets the same failure, which is a reason to measure it. A measurement
  needs a real large upload, so it needs the owner's go.
- The simulator runs background sessions only in part and cannot show a relaunch after the app was ended.

## Left to the builder

Names and signatures (the names above are suggestions); the record's file format and version; the progress throttle; the free-space margin; the exact wording of the failure messages (English, like the rest of the app); how the Upload
tab lays out the failed and finished states; whether the cut 1 helper lives beside `BackgroundLocationMonitor` or in a common
folder; the test names; the text of ADR 008.

## Calls the author made (open to correction)

- One upload at a time, one record.
- Cellular and Low Data Mode are allowed for the transfer, because the viewer asked for it.
- The key travels in an `Idempotency-Key` header, so the Worker can answer before it reads up to 100 MB. A replay answers 200,
  a new clip 201.
- No automatic resubmission from a background wake (see Non-goals); the viewer taps Try again. The one exception is a 401, so
  an expired token never shows as a failure. 24 h is the total ceiling for one upload.
- A session the Worker ended keeps the unsent clip for the same account, 7 days at most; an explicit Sign Out and another
  account's sign-in delete it.
- A finished upload is reported to the app's flow (feed reload, focus, Feed tab) only when the app is active. No local
  notification.
- The record and the body live in Application Support, excluded from backup.
- After cut 2 the video upload uses the background path only; the in-process `HTTPClient.upload` stays for the avatar and the
  dubbed-audio uploads.
- Two implementation plans: cut 1 now, cut 2 after cut 1 has landed and its phone results are in.

## Evidence

Apple Developer Forums, read on 2026-11-15:
[BGContinuedProcessingTask pauses when the device is locked](https://developer.apple.com/forums/thread/796138),
[issues with the BGContinuedProcessingTask API](https://developer.apple.com/forums/thread/805088),
[background URLSession uploads stalled by scheduler budget policies](https://developer.apple.com/forums/thread/849761)
(also: background sessions accept file uploads only). The swipe-away cancellation and the no-async/await limit of background
sessions come from search results of
[this thread](https://developer.apple.com/forums/thread/765196) and related ones, not from Apple's documentation; the builder
confirms both there. [WWDC25 session 227](https://developer.apple.com/videos/play/wwdc2025/227/) describes
`BGContinuedProcessingTask`.
