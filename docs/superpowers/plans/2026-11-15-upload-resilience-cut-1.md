# Upload Resilience, Cut 1: Progress, Streaming and a Safety Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A viewer who taps Upload sees how far the clip has got, the app never holds the whole clip in memory while it uploads, and a viewer who leaves the app mid-upload gets the system's short grace period (about 30 seconds) for the upload to finish.

**Architecture:** `HTTPMultipartPart` gets a file-backed case that a new `MultipartBodyWriter` copies into the body in 1 MiB chunks. `HTTPClient` gets a second `upload` requirement that takes a progress handler (a protocol-extension default calls the old one, so every existing double is untouched); `URLSessionHTTPClient` fills it from a task delegate and the three wrappers forward it. Domain carries one callback type through `VideoUploadRepository` and `UploadFeedVideoUseCase`. `UploadVideoViewModel` publishes the progress and holds a background task for the whole upload through a Presentation helper (`BackgroundExecution`) that `BackgroundLocationMonitor` shares. No Worker change, no migration.

**Tech Stack:** Swift 6.4 (Xcode 27.2) with default MainActor isolation, SwiftUI, Swift Testing, `URLSession`, and Network.framework for one test helper.

**Spec:** `docs/superpowers/specs/2026-11-15-upload-resilience-design.md`, "Design: cut 1", with "Goals", "Non-goals", "Anti-goals" and "Verification". Read it first. This plan adds only what the spec leaves to the builder; where it goes beyond the spec it says so under "Calls this plan makes". Cut 2 (the background session, the durable body, the Worker idempotency key) is not in this plan.

## Global Constraints

- **Scope:** app only. No Worker change, no migration, no new dependency. The avatar upload (`UserProfileAPIClient`, which keeps sending `.file(data:)`), the dubbed-audio upload and every installed build keep working as they do.
- **Chunk:** 1 MiB (`1_048_576`) per read, and each chunk's read and write sit inside `autoreleasepool`. A `FileHandle` read returns autoreleased `NSData`, which would otherwise pile up until the task ends and bring the whole clip back into memory.
- **Progress value:** a `Double` from 0 to 1, the bytes of the multipart body sent so far over its length. An unknown or zero total is ignored; the value is clamped to 0...1. The handler type is `UploadProgressHandler = @Sendable (_ fraction: Double) -> Void`, defined once in Domain (`Domain/Repositories/VideoUploadRepository.swift`) and called on any thread.
- **Throttle:** one report when the whole percent (`Int(fraction * 100)`) differs from the last one that transfer reported, so at most 101 reports per transfer. Every transfer, a replay after a 401 included, has its own delegate and starts again at 0.
- **Texts (exact):** `Uploading… 42%` (the percent is rounded down, so a clip can read 99% but never 100%) and `Finishing…` (every byte sent, no answer yet). Both use the single character `…` (U+2026) like the other texts of the view. No other new string; English only.
- **Safety net:** `UIApplication.beginBackgroundTask` named `Upload video`, begun when Upload is tapped (after the two guards that return early) and ended exactly once on every way out. The expiration handler ends the task and does nothing else.
- **Isolation:** new Data-layer members are `nonisolated` like their neighbours (the Presentation ones stay on the main actor); the long file copy is `@concurrent`.
- **Layers** (`Scripts/check-layers.sh`): Domain imports Foundation only; Data names no Presentation type; Presentation names no Data type; a `*View.swift` names no use case or repository. No new line in `Scripts/layer-exceptions.txt`.
- **Format:** swift-format `lineLength` 120; the files a task touches lint clean.
- **Xcode:** new Swift files in the synchronized groups need no `project.pbxproj` edit. All targets are iOS 27.0.
- **Logs:** no path of a clip, caption, coordinate or token in `AppLog` (as today); byte counts are fine.
- **Git:** stage named files only, never `git add -A`. The owner's main checkout has an unrelated uncommitted edit in `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` (an `await` removed from the `AppLog.warning` at line 41). Work in a worktree, where that file has its committed text; leave that line alone, never copy the owner's edit into the branch and never touch it in main. Commit, push and merge each need the owner's yes (see "Before Task 1").

## Review Focus

Five inputs the spec implies but a happy-path test would miss, most likely first, each pinned by a test:

1. **The first try is rejected after it reported "everything sent"** (a 401 meets an upload that was fully sent; the app refreshes the token and sends the upload again). Expect the bar to go back to 0 and the row to stop saying `Finishing…` while the second try sends, with one handler serving both tries. Pinned by Task 3 `anUploadReportsProgressForTheFirstTryAndTheReplay` and Task 5 `aReportThatRestartsAtZeroLowersTheBar`.
2. **A report arrives after the upload is over.** Progress hops to the main actor, so a late report can land after success, after a failure, or after the next upload has started. Expect nothing to change and no bar left on the Upload tab. Pinned by Task 5 `aLateReportAfterTheUploadEndedChangesNothing` and `aReportFromAnEarlierUploadCannotMoveTheNextBar`.
3. **The clip is gone or unreadable when the body is written** (the system purged the temporary folder while the app was away). Expect an error before any request goes out and no half-written body left behind. Pinned by Task 1 `aClipFileThatIsGoneFailsBeforeTheRequestAndLeavesNoBody`.
4. **A clip whose size falls on a chunk edge** (0 bytes, exactly one chunk, one byte over, several chunks). Expect the same body, byte for byte, as the in-memory path gives. Pinned by Task 1 `aFileBackedPartMakesTheSameBodyAsTheSameBytesInMemory`.
5. **The background task is begun and never ended, or ended twice** (a thrown error, a cancellation, a server answer, a tap that starts nothing). Expect one begin and one end per upload, and none for a tap that returns early. Pinned by Task 6 `theUploadHoldsABackgroundTaskUntilItEnds`, `theTaskIsReleasedOnceWhenTheUploadFails`, `theTaskIsReleasedOnceWhenTheUploadIsCancelled` and `aTapThatStartsNothingHoldsNoTask`.

Also pinned, because the spec lists them or the design invites them: a wrapper that forgets to forward progress would drop it silently (the protocol default hides the omission), so each wrapper and the real stack have a forwarding test (Task 3); an old double that knows only the two-argument `upload` still works (Task 2); the real delegate wiring is proven over a real socket, because `didSendBodyData` never arrives through a `URLProtocol` stub (Task 2); the bar never reads 100% before the Worker answers (Task 5).

## How to run things

- **Paths** are relative to `Marauders-ios/` (app code under `Marauders/`, tests under `MaraudersTests/`), except `docs/...` and `ARCHITECTURE.md`, which are relative to the repository root. Commands run from the worktree's root.
- **Tests run on the iOS 27.2 simulator** (the owner's rule; the phone only when the owner asks). `$SCRATCH` is a throwaway folder outside the repo:
  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme Marauders \
    -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' \
    -derivedDataPath "$SCRATCH/DerivedData-sim" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" \
    -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
  ```
  That id is the iPhone 17 on iOS 27.2 (`xcrun simctl list devices available` shows it). If a run says the device is busy: `xcrun simctl boot <id>` then `xcrun simctl bootstatus <id> -b`. Only an iOS 27.2 simulator qualifies, because every target is iOS 27.0. A task's "Run" step uses this command with the suites it names. Read the result by grepping the output for ` error: ` and `✘`; a pass ends with `** TEST SUCCEEDED **`. A compile error is the expected state of every "see it fail" step. Suites run in parallel, so a test that depends on wall-clock time can flake under load: run it alone before reading a red as real. The whole unit target (`-only-testing:MaraudersTests`) was 1026 tests in 95 suites and about 5 s of test time once built, before this work.
- **UI target** (52 tests, 16 to 34 minutes on the simulator): run once, in Task 7, detached so it survives the tool timeout: `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c "xcodebuild test <same arguments> -only-testing:MaraudersUITests > $SCRATCH/ui.log 2>&1; echo exit=\$? >> $SCRATCH/ui.log"`, then wait for `exit=` in the log. The baseline is 51 of 52: the one red is `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` (a system Translate sheet that a simulator shows). A test cut short by a crash of Xcode's `testmanagerd` (the log says "Restarting after unexpected exit, crash, or test timeout") has no `error:` line of its own: run it alone before reading it as a regression. macOS has no `timeout` command.
- **Layer checker:** `sh Marauders-ios/Scripts/check-layers.sh` prints nothing when clean.
- **swift-format:** `cd Marauders-ios && xcrun swift-format lint <the files the task touched>` prints nothing when clean.
- **Release compile check:** `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme Marauders -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/DerivedData-release" -archivePath "$SCRATCH/Marauders.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`.

## File Structure

| Area | Create | Modify |
|------|--------|--------|
| Domain | | `Domain/Repositories/VideoUploadRepository.swift` (the handler type and a third `upload` overload), `Domain/UseCases/UploadFeedVideoUseCase.swift` |
| Data | `Data/API/MultipartBodyWriter.swift`, `Data/API/UploadProgressDelegate.swift` | `Data/API/HTTPClient.swift`, `VideoUploadAPIClient.swift`, `RetryingHTTPClient.swift`, `TokenRefreshingHTTPClient.swift`, `RejectedSessionReportingHTTPClient.swift`, `Data/Repositories/DefaultVideoUploadRepository.swift` |
| Presentation | `Presentation/Common/BackgroundExecution.swift` | `Presentation/Upload/UploadVideoViewModel.swift`, `UploadVideoView.swift`, `Presentation/Map/BackgroundLocationMonitor.swift` |
| Tests | `MultipartBodyWriterTests`, `MultipartBodyWriterMemoryTests`, `UploadProgressTests`, `BackgroundExecutionTests`, `Support/LoopbackHTTPServer.swift`, `Support/ProgressLog.swift` | `Support/RecordingTransport.swift`, `URLSessionHTTPClientTests`, `VideoUploadAPIClientTests`, `RetryingHTTPClientTests`, `TokenRefreshingHTTPClientTests`, `RejectedSessionReportingTests`, `APITransportCompositionTests`, `UploadFeedVideoUseCaseTests`, `UploadVideoViewModelTests` (all under `MaraudersTests/`) |
| Docs | | `ARCHITECTURE.md` |

## Calls this plan makes (beyond the spec; the owner may overrule any)

1. **`MultipartBodyWriter` is extracted** from the private extension of `URLSessionHTTPClient` into its own file. Cut 2 stages its durable body with the same writer from outside the client, and the spec calls it "the same chunked writer".
2. **Reports come at whole-percent changes** (at most 101 a transfer), and each transfer gets a new delegate, so a replay restarts at 0 and the main actor is not flooded for a 100 MB clip. The spec leaves the throttle to the builder.
3. **The percent is rounded down** and a full body reads `Finishing…`, so the row never says 100% before the Worker answers (an anti-goal of the spec).
4. **The view model formats the progress label** (it already formats `statusMessage`), so the texts are unit-tested instead of left in a view.
5. **The safety net begins when Upload is tapped**, not around the 720p export, which the spec lists as a non-goal. `BackgroundExecution` lives in `Presentation/Common/` and keeps the exact signature `BackgroundLocationMonitor` already takes for `holdAwake`, so the monitor changes by deleting its private copy.
6. **The delegate wiring is proven over a real loopback socket** (`LoopbackHTTPServer`). A probe on 2026-11-15 (a macOS command-line program, a `URLProtocol` that reads the body stream and one that does not) saw zero `didSendBodyData` calls, so the project's `StubURLProtocol` cannot show progress.
7. **The memory claim is proven by a gated test** (`MEASURE_UPLOAD_MEMORY=1`), run once in Task 1 and skipped in normal runs, because a footprint reading is not stable while suites run in parallel.
8. **No UI test is added.** No UI test covers upload today, and a real upload would reach the production Worker.

## Before Task 1

- [ ] Ask the owner once, in one message: (a) commit `docs/superpowers/` (the spec, whose Status line now says approved, and this plan) as one commit on `main`; (b) do the work in a worktree on its own branch, `claude/upload-resilience-cut-1` (`superpowers:using-git-worktrees`), cut from `main` after that commit, so the unrelated `RetryingHTTPClient.swift` edit stays in `main`'s tree only; (c) may each task's local commit below be made as the task passes. A push and the merge are asked separately, each time. Say plainly that merging this branch touches `RetryingHTTPClient.swift`, so git will refuse the merge while the owner's edit there is uncommitted: they commit or stash it first, or give a go-ahead for another way.

---

### Task 1: Stream the clip from disk

**Files:**
- Create: `Marauders/Data/API/MultipartBodyWriter.swift`, `MaraudersTests/MultipartBodyWriterTests.swift`, `MaraudersTests/MultipartBodyWriterMemoryTests.swift`
- Modify: `Marauders/Data/API/HTTPClient.swift`, `Marauders/Data/API/VideoUploadAPIClient.swift`, `MaraudersTests/Support/RecordingTransport.swift`, `MaraudersTests/URLSessionHTTPClientTests.swift`, `MaraudersTests/VideoUploadAPIClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // HTTPClient.swift
  enum HTTPMultipartPart: Sendable {
      case field(name: String, value: String)
      case file(name: String, filename: String, mimeType: String, data: Data)
      case fileAt(name: String, filename: String, mimeType: String, url: URL)  // new: copied in chunks
  }
  // MultipartBodyWriter.swift
  nonisolated enum MultipartBodyWriter {
      static let defaultChunkSize = 1_048_576
      @concurrent static func write(
          _ parts: [HTTPMultipartPart], boundary: String, to url: URL,
          chunkSize: Int = MultipartBodyWriter.defaultChunkSize
      ) async throws
  }
  // RecordingTransport.RecordedPart gains: case fileAt(name: String, filename: String, mimeType: String, url: URL)
  ```
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests.**
  - `RecordingTransport`: add the `fileAt` case to `RecordedPart` and to `recorded(_:)` (the exhaustive switch breaks without it); update its doc comment.
  - `MultipartBodyWriterTests`: `aFileBackedPartMakesTheSameBodyAsTheSameBytesInMemory`, `@Test(arguments: [0, 1, 3, 4, 5, 8, 11])` over the clip size, with `chunkSize: 4`. The bytes are `Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })`. Write `[.field(name: "latitude", value: "13.5"), .fileAt(name: "file", filename: "clip.mp4", mimeType: "video/mp4", url: <temp file holding the bytes>)]` and the same with `.file(..., data: bytes)` to two temp files with boundary `"b"`; `#expect` the two files' contents equal. Also `aMissingSourceFileThrows`: a `.fileAt` whose URL does not exist, `await #expect(throws: (any Error).self)`.
  - `URLSessionHTTPClientTests`: `uploadSendsALargeFileFromDiskWithoutLosingBytes` (the assertions of `uploadSendsALargeFileWithoutLosingBytes`, with the 3_000_000 bytes in a temp file and a `.fileAt` part, so the copy spans three chunks) and `aClipFileThatIsGoneFailsBeforeTheRequestAndLeavesNoBody` (a `.fileAt` whose file does not exist, a scratch `temporaryDirectory`; the stub handler records an `Issue` if reached; expect `HTTPClientError.transport` and `contentsOfDirectory` of the scratch folder empty).
  - `VideoUploadAPIClientTests`: `uploadSendsTheClipAsAFileBackedPartAndNeverAsData`: a `RecordingTransport` with one 201 answer (`uploadResponseJSON`) as `client:`, caption `"Sunset"`; `#expect(transport.uploadedParts == [[.field(name: "latitude", value: "13.7563"), .field(name: "longitude", value: "100.5018"), .field(name: "caption", value: "Sunset"), .fileAt(name: "file", filename: fileURL.lastPathComponent, mimeType: "video/mp4", url: fileURL)]])`.
- [ ] **Step 2: Run** `MultipartBodyWriterTests`, `URLSessionHTTPClientTests`, `VideoUploadAPIClientTests`. Expected: the build fails with `type 'HTTPMultipartPart' has no member 'fileAt'` and `cannot find 'MultipartBodyWriter' in scope`.
- [ ] **Step 3: Implement.**
  - `HTTPMultipartPart.fileAt` as above.
  - `MultipartBodyWriter.write`: move `writeMultipartBody` and `escaped` out of `URLSessionHTTPClient`'s private extension unchanged, then add the `.fileAt` branch: write the part head as the `.file` branch does, open the source with `FileHandle(forReadingFrom:)` (closed in a `defer`), and loop `try autoreleasepool { ... }` reading `max(1, chunkSize)` bytes with `read(upToCount:)` and writing them, until the read gives `nil` or empty data.
  - `URLSessionHTTPClient.upload` calls `MultipartBodyWriter.write(multipart, boundary: boundary, to: bodyFile)`; its `defer` that removes the body file stays, so a failed copy leaves nothing.
  - `VideoUploadAPIClient.upload`: delete `let fileData = try Data(contentsOf: fileURL)`; `multipartParts` takes the `fileURL` and appends `.fileAt(name: "file", filename: fileURL.lastPathComponent, mimeType: mimeType, url: fileURL)`. The size check on the file's attributes stays as it is.
- [ ] **Step 4: Run** the three suites again and `TokenRefreshingHTTPClientTests` (it uses `RecordingTransport`). Expected: all pass. `grep -n "Data(contentsOf" Marauders-ios/Marauders/Data/API/VideoUploadAPIClient.swift` prints nothing.
- [ ] **Step 5: Prove the memory claim once.** Add `MultipartBodyWriterMemoryTests` with one test, `aLargeClipIsCopiedWithoutHoldingItWhole`, gated by `.enabled(if: ProcessInfo.processInfo.environment["MEASURE_UPLOAD_MEMORY"] == "1")`: make a 192 MiB sparse file (`FileHandle.truncate(atOffset:)`), read the process's `phys_footprint` (`task_info` with `TASK_VM_INFO`) as the baseline, run a sampler task that keeps the maximum footprint every 2 ms, run `MultipartBodyWriter.write([.fileAt(...)], boundary: "b", to: out)`, stop the sampler, `print("[upload.memory] peak growth MiB=...")` and `#expect(peakGrowth < 48 * 1024 * 1024)`; delete both files. Run it with `TEST_RUNNER_MEASURE_UPLOAD_MEMORY=1` before the xcodebuild command and `-only-testing:MaraudersTests/MultipartBodyWriterMemoryTests`, first with the `.fileAt` branch temporarily replaced by `try handle.write(contentsOf: Data(contentsOf: url))`. Expected: the test fails with a growth above 150 MiB (so the test can see a whole read). Restore the chunked loop and run again. Expected: it passes; note the printed number for the report. Run the suite without the variable. Expected: the test is skipped.
- [ ] **Step 6: Commit:** `git add Marauders-ios/Marauders/Data/API/MultipartBodyWriter.swift Marauders-ios/Marauders/Data/API/HTTPClient.swift Marauders-ios/Marauders/Data/API/VideoUploadAPIClient.swift Marauders-ios/MaraudersTests/MultipartBodyWriterTests.swift Marauders-ios/MaraudersTests/MultipartBodyWriterMemoryTests.swift Marauders-ios/MaraudersTests/Support/RecordingTransport.swift Marauders-ios/MaraudersTests/URLSessionHTTPClientTests.swift Marauders-ios/MaraudersTests/VideoUploadAPIClientTests.swift` → "Stream a clip into the upload body in chunks instead of reading it whole".

### Task 2: Progress at the transport

**Files:**
- Create: `Marauders/Data/API/UploadProgressDelegate.swift`, `MaraudersTests/UploadProgressTests.swift`, `MaraudersTests/Support/LoopbackHTTPServer.swift`, `MaraudersTests/Support/ProgressLog.swift`
- Modify: `Marauders/Domain/Repositories/VideoUploadRepository.swift` (the handler type only), `Marauders/Data/API/HTTPClient.swift`, `MaraudersTests/URLSessionHTTPClientTests.swift`

**Interfaces:**
- Consumes: Task 1's `HTTPMultipartPart.fileAt`.
- Produces:
  ```swift
  // Domain/Repositories/VideoUploadRepository.swift
  typealias UploadProgressHandler = @Sendable (_ fraction: Double) -> Void
  // HTTPClient.swift: a third requirement, and a default for it
  protocol HTTPClient: Sendable {
      func data(_ request: URLRequest) async throws -> HTTPClientResponse
      func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse
      func upload(_ request: URLRequest, multipart: [HTTPMultipartPart], progress: UploadProgressHandler?) async throws
          -> HTTPClientResponse
  }
  extension HTTPClient {  // nonisolated; calls the two-argument form and never reports
      func upload(_ request: URLRequest, multipart: [HTTPMultipartPart], progress: UploadProgressHandler?) async throws
          -> HTTPClientResponse
  }
  // UploadProgressDelegate.swift
  nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
      init(handler: @escaping UploadProgressHandler)
      func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                      totalBytesSent: Int64, totalBytesExpectedToSend: Int64)
  }
  // Support: LoopbackHTTPServer (init(status: Int = 201, body: Data = Data(#"{"ok":true}"#.utf8));
  //   func start() async throws -> URL; var receivedBodyByteCounts: [Int]; func stop())
  //   and ProgressLog (thread-safe: var values: [Double]; var handler: UploadProgressHandler)
  ```

- [ ] **Step 1: Write the failing tests** in `UploadProgressTests.swift` and `URLSessionHTTPClientTests.swift`. For the delegate tests call `urlSession(_:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)` directly with `URLSession.shared` and a task from `URLSession.shared.dataTask(with:)` that is never resumed.
  - `UploadProgressDelegateTests`: `itReportsTheFractionSentAndEndsAtOne` (total 1000: sent 250 gives `[0.25]`, then sent 1000 gives `[0.25, 1.0]`); `itReportsOnlyWhenTheWholePercentChanges` (1000 calls, sent 1 through 1000 of 1000: at most 101 reports, non-decreasing, last `== 1.0`, all in 0...1); `itIgnoresAnUnknownOrZeroTotal` (totals `-1` and `0` report nothing); `itNeverReportsMoreThanOne` (sent 1200 of 1000 gives `[1.0]`); `itReportsAgainWhenTheBodyIsSentFromTheStart` (sent 900 then 100 of 1000 gives `[0.9, 0.1]`).
  - `HTTPClientProgressDefaultTests`: `aClientThatOnlyKnowsTheOldUploadStillUploadsAndNeverReports`: `ScriptedHTTP(status: 201)` (the two-argument-only double in `RejectedSessionReportingTests.swift`), `upload(request, multipart: [.field(name: "a", value: "b")], progress: log.handler)` gives status 201, `base.requests.count == 1`, `log.values.isEmpty`.
  - `URLSessionHTTPClientTests.uploadReportsProgressOverARealConnectionAndEndsAtOne` (`.timeLimit(.minutes(1))`): `LoopbackHTTPServer` started, `URLSessionHTTPClient(session: URLSession(configuration: .ephemeral))`, a POST to the server's URL, parts `[.fileAt(...)]` over a 3_000_000-byte temp file, a `ProgressLog` handler. Expect status 201; `log.values` not empty, every value in 0...1, non-decreasing, last `== 1.0`; the server's `receivedBodyByteCounts.first` at least 3_000_000. If the transfer fails with `NSURLErrorAppTransportSecurityRequiresSecureConnection` (-1022), try `http://localhost:<port>/` before anything else; if that is refused too, add no ATS exception to the app, record a `Ruling:` and keep the delegate tests plus Task 3's forwarding tests as the automated proof, naming the phone check as the wiring's proof.
- [ ] **Step 2: Run** `UploadProgressTests`, `URLSessionHTTPClientTests`. Expected: the build fails with `cannot find type 'UploadProgressHandler'` and `cannot find 'UploadProgressDelegate'`.
- [ ] **Step 3: Implement.**
  - `UploadProgressHandler` at the top of `VideoUploadRepository.swift`, with a doc comment that it is called on any thread.
  - The protocol requirement and its `nonisolated` default; if the compiler objects to the isolation of the default, follow its fix-it and keep the default callable from a `nonisolated` conformer.
  - `UploadProgressDelegate`: ignore a total of 0 or less; `fraction = min(max(Double(totalBytesSent) / Double(total), 0), 1)`; keep the last reported whole percent (`Int?`, `nil` at first) behind a lock and call the handler when the new whole percent differs, so the first call always reports and a body sent again from the start reports again.
  - `URLSessionHTTPClient`: `upload(_:multipart:)` calls `upload(_:multipart:progress: nil)`; the three-argument form is the old body of `upload`, with `try await session.upload(for: request, fromFile: bodyFile, delegate: progress.map { UploadProgressDelegate(handler: $0) })`, a new delegate per call.
  - `LoopbackHTTPServer` on Network.framework: an `NWListener` bound to `127.0.0.1` (`NWParameters.tcp` with `requiredLocalEndpoint`), `start()` waits for the `ready` state and returns `http://127.0.0.1:<port>/`; per connection it reads until the blank line, takes `Content-Length`, counts that many body bytes, then answers `HTTP/1.1 <status>` with `Content-Length`, `Connection: close` and the body, and closes. `ProgressLog` keeps its values behind a lock.
- [ ] **Step 4: Run** `UploadProgressTests`, `URLSessionHTTPClientTests`, `RejectedSessionReportingTests`, `RetryingHTTPClientTests`, `TokenRefreshingHTTPClientTests`, `DubbedAudioCacheTests`. Expected: all pass, with no change to the other doubles.
- [ ] **Step 5: Commit:** `git add Marauders-ios/Marauders/Data/API/UploadProgressDelegate.swift Marauders-ios/Marauders/Data/API/HTTPClient.swift Marauders-ios/Marauders/Domain/Repositories/VideoUploadRepository.swift Marauders-ios/MaraudersTests/UploadProgressTests.swift Marauders-ios/MaraudersTests/Support/LoopbackHTTPServer.swift Marauders-ios/MaraudersTests/Support/ProgressLog.swift Marauders-ios/MaraudersTests/URLSessionHTTPClientTests.swift` → "Report upload progress from URLSessionHTTPClient through a task delegate".

### Task 3: The wrappers forward progress

**Files:**
- Modify: `Marauders/Data/API/RetryingHTTPClient.swift`, `Marauders/Data/API/TokenRefreshingHTTPClient.swift`, `Marauders/Data/API/RejectedSessionReportingHTTPClient.swift`, `MaraudersTests/Support/RecordingTransport.swift`, `MaraudersTests/RetryingHTTPClientTests.swift`, `MaraudersTests/TokenRefreshingHTTPClientTests.swift`, `MaraudersTests/RejectedSessionReportingTests.swift`, `MaraudersTests/APITransportCompositionTests.swift`

**Interfaces:**
- Consumes: Task 2's three-argument `HTTPClient.upload`, `ProgressLog`.
- Produces: `RecordingTransport.init(_ script: [Result<HTTPClientResponse, any Error>], reportingProgress: [Double] = [])` (and the same extra parameter on `init(responder:)`): its three-argument `upload` records the parts like the two-argument form, then calls `progress` with each value in `reportingProgress` before it answers; its two-argument `upload` calls the three-argument one with `nil`.

- [ ] **Step 1: Write the failing tests** (each reads the values through a `ProgressLog`):
  - `RetryingHTTPClientTests.anUploadForwardsItsProgressAndIsStillNeverRepeated`: `RecordingTransport([.success(503), .success(201)], reportingProgress: [0.25])` under `RetryingHTTPClient(base:, maxAttempts: 3, delayNanoseconds: { _ in 0 })`; the answer is 503, `transport.requests.count == 1`, `log.values == [0.25]`.
  - `TokenRefreshingHTTPClientTests.anUploadReportsProgressForTheFirstTryAndTheReplay`: the transport answers `[401, 201]` and reports `[0.5, 1.0]`, the refresher answers `.refreshed("new")`; the answer is 201 and `log.values == [0.5, 1.0, 0.5, 1.0]`.
  - `RejectedSessionReportingTests.anUploadForwardsItsProgressAndStillReportsA401`: a transport answering `[401]` and reporting `[1.0]`; `reports.tokens == [token]` and `log.values == [1.0]`.
  - `APITransportCompositionTests.theApiStackDeliversUploadProgressToTheCaller`: a `RecordingTransport` answering `[201]` and reporting `[0.5, 1.0]` as the `base` of `APITransportComposition.api(base:refresher:reportRejected:)` with a `ScriptedRefresher()`; an upload with a `ProgressLog` handler gives `log.values == [0.5, 1.0]`.
- [ ] **Step 2: Run** the four suites. Expected: the progress tests fail (an empty `log.values`) or the build fails on `reportingProgress:`.
- [ ] **Step 3: Implement** the three-argument `upload` on each wrapper, and make its two-argument form call it with `nil`. `RetryingHTTPClient` passes `progress` to `base.upload(request, multipart: multipart, progress: progress)` and still never repeats an upload; `TokenRefreshingHTTPClient` puts `base.upload($0, multipart: multipart, progress: progress)` inside the closure it hands to `send`, so the replay reports through the same handler; `RejectedSessionReportingHTTPClient` forwards and reports a 401 as before. In `RetryingHTTPClient.swift` change only the `upload` function (the worktree has the committed text of line 41: leave it). Extend `RecordingTransport` as above.
- [ ] **Step 4: Run** the four suites, then the whole unit target. Expected: all pass.
- [ ] **Step 5: Commit:** `git add Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift Marauders-ios/Marauders/Data/API/TokenRefreshingHTTPClient.swift Marauders-ios/Marauders/Data/API/RejectedSessionReportingHTTPClient.swift Marauders-ios/MaraudersTests/Support/RecordingTransport.swift Marauders-ios/MaraudersTests/RetryingHTTPClientTests.swift Marauders-ios/MaraudersTests/TokenRefreshingHTTPClientTests.swift Marauders-ios/MaraudersTests/RejectedSessionReportingTests.swift Marauders-ios/MaraudersTests/APITransportCompositionTests.swift` → "Forward upload progress through the retry, refresh and reporting wrappers".

### Task 4: Progress through the API client, repository and use case

**Files:**
- Modify: `Marauders/Data/API/VideoUploadAPIClient.swift`, `Marauders/Domain/Repositories/VideoUploadRepository.swift`, `Marauders/Data/Repositories/DefaultVideoUploadRepository.swift`, `Marauders/Domain/UseCases/UploadFeedVideoUseCase.swift`, `MaraudersTests/VideoUploadAPIClientTests.swift`, `MaraudersTests/UploadFeedVideoUseCaseTests.swift`

**Interfaces:**
- Consumes: Task 2's `UploadProgressHandler` and three-argument `upload`, Task 3's `RecordingTransport(_:reportingProgress:)`.
- Produces:
  ```swift
  // VideoUploadAPIClient
  func upload(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String = "",
              audioAssessment: ClipAudioAssessment? = nil, progress: UploadProgressHandler? = nil) async throws -> FeedVideo
  // VideoUploadRepository: a third requirement, and a default that calls the five-argument one without progress
  func upload(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
              audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?) async throws -> FeedVideo
  // UploadFeedVideoUseCase
  func execute(fileURL: URL, clipLocation: ClipLocation, mimeType: String = "video/mp4", caption: String = "",
               audioAssessment: ClipAudioAssessment? = nil, progress: UploadProgressHandler? = nil) async throws -> FeedVideo
  ```

- [ ] **Step 1: Write the failing tests.**
  - `VideoUploadAPIClientTests.uploadReportsHowMuchOfTheBodyWasSent`: a `RecordingTransport` answering 201 and reporting `[0.4, 1.0]` as `client:`; `upload(..., progress: log.handler)` returns the decoded item and `log.values == [0.4, 1.0]`. `theRepositoryAndTheUseCaseDeliverProgressToo`: the same transport under `UploadFeedVideoUseCase(repository: DefaultVideoUploadRepository(apiClient: ...))`; `execute(..., progress: log.handler)` gives `log.values == [0.4, 1.0]`.
  - `UploadFeedVideoUseCaseTests.executeForwardsTheProgressHandlerToTheRepository`: a private repository double that implements the new overload and reports `0.5` through it; `log.values == [0.5]`. `aRepositoryThatKnowsNothingOfProgressStillUploads`: `RecordingVideoUploadRepository` (the four-argument double, untouched) with a handler gives the stored video, `repository.uploadCount == 1`, `log.values.isEmpty`.
- [ ] **Step 2: Run** `VideoUploadAPIClientTests`, `UploadFeedVideoUseCaseTests`. Expected: the build fails with `extra argument 'progress' in call`.
- [ ] **Step 3: Implement.** `VideoUploadAPIClient` passes `progress` to `client.upload(request, multipart: parts, progress: progress)`. `VideoUploadRepository` gets the third requirement and its extension default (calls the five-argument form). `DefaultVideoUploadRepository` implements the new overload by calling the API client, and its two older overloads call it with `progress: nil`. `UploadFeedVideoUseCase.execute` calls the repository's new overload.
- [ ] **Step 4: Run** `VideoUploadAPIClientTests`, `UploadFeedVideoUseCaseTests`, `UploadVideoViewModelTests`, `AppCoordinatorTests`. Expected: all pass.
- [ ] **Step 5: Commit:** `git add Marauders-ios/Marauders/Data/API/VideoUploadAPIClient.swift Marauders-ios/Marauders/Domain/Repositories/VideoUploadRepository.swift Marauders-ios/Marauders/Data/Repositories/DefaultVideoUploadRepository.swift Marauders-ios/Marauders/Domain/UseCases/UploadFeedVideoUseCase.swift Marauders-ios/MaraudersTests/VideoUploadAPIClientTests.swift Marauders-ios/MaraudersTests/UploadFeedVideoUseCaseTests.swift` → "Carry the upload progress handler through the API client, repository and use case".

### Task 5: The Upload tab shows how far the upload has got

**Files:**
- Modify: `Marauders/Presentation/Upload/UploadVideoViewModel.swift`, `Marauders/Presentation/Upload/UploadVideoView.swift`, `MaraudersTests/UploadVideoViewModelTests.swift`

**Interfaces:**
- Consumes: Task 4's `UploadFeedVideoUseCase.execute(..., progress:)`.
- Produces on `UploadVideoViewModel`:
  ```swift
  var uploadProgress: Double?        // nil unless isUploading; 0 when the upload starts; 0...1
  var isFinishingUpload: Bool        // isUploading && (uploadProgress ?? 0) >= 1
  var uploadProgressLabel: String?   // nil, "Uploading… 42%", or "Finishing…"
  ```

- [ ] **Step 1: Write the failing tests** in `UploadVideoViewModelTests`, with a private repository double that implements the progress overload, captures the handler, reports on demand and holds the upload until the test releases it (success or failure), like the file's `DeferredInspector`:
  - `theBarStartsAtZeroWhenTheUploadStarts`: while the double holds the upload, `uploadProgress == 0` and `uploadProgressLabel == "Uploading… 0%"`.
  - `theLabelRoundsDownAndEndsWithTheUpload`: a report of 0.425 gives `"Uploading… 42%"`; 0.999 gives `"Uploading… 99%"`; after the upload ends `uploadProgress == nil` and `uploadProgressLabel == nil`.
  - `allBytesSentShowsFinishingNotOneHundredPercent`: a report of 1.0 gives `isFinishingUpload`, label `"Finishing…"`, and the label does not contain `"100"`.
  - `aReportThatRestartsAtZeroLowersTheBar`: reports 1.0 then 0.1 give `uploadProgress == 0.1` and `!isFinishingUpload`.
  - `aReportIsClampedToTheRange`: 1.7 gives 1.0; -0.3 gives 0.
  - `aLateReportAfterTheUploadEndedChangesNothing`: keep the handler, finish the upload, call the handler with 0.97, let the main actor settle (a few `Task.yield()`s); `uploadProgress == nil`.
  - `aReportFromAnEarlierUploadCannotMoveTheNextBar`: the first upload fails and its handler is kept; a second upload starts; the old handler reports 0.9; `uploadProgress == 0`.
- [ ] **Step 2: Run** `UploadVideoViewModelTests`. Expected: the build fails with `value of type 'UploadVideoViewModel' has no member 'uploadProgress'`.
- [ ] **Step 3: Implement.** In `upload()`: after the guards, `isUploading = true`, `uploadProgress = 0`, bump a private `uploadAttempt` counter and keep its value; `defer` also clears `uploadProgress`; pass `progress: { [weak self] fraction in Task { @MainActor in self?.applyUploadProgress(fraction, attempt: attempt) } }` to `uploadVideo.execute`; `applyUploadProgress` is private, returns unless `isUploading && attempt == uploadAttempt`, and stores `min(max(fraction, 0), 1)`. `uploadProgressLabel` is `nil` without a progress, `"Finishing…"` from 1.0, otherwise `"Uploading… \(Int((progress * 100).rounded(.down)))%"`. In `UploadVideoView`, inside the upload button's label where `Uploading…` shows today: while `isFinishingUpload` an indeterminate `ProgressView()` beside the label; otherwise `ProgressView(value: viewModel.uploadProgress ?? 0)` above the label; both with `.accessibilityIdentifier("upload.progress")`; with no label (not possible once an upload runs) keep today's `ProgressView()` and `Uploading…`. The view names no use case.
- [ ] **Step 4: Run** `UploadVideoViewModelTests`, `AppCoordinatorTests`. Expected: all pass.
- [ ] **Step 5: Commit:** `git add Marauders-ios/Marauders/Presentation/Upload/UploadVideoViewModel.swift Marauders-ios/Marauders/Presentation/Upload/UploadVideoView.swift Marauders-ios/MaraudersTests/UploadVideoViewModelTests.swift` → "Show how far an upload has got in the Upload tab".

### Task 6: Hold a background task while a clip uploads

**Files:**
- Create: `Marauders/Presentation/Common/BackgroundExecution.swift`, `MaraudersTests/BackgroundExecutionTests.swift`
- Modify: `Marauders/Presentation/Map/BackgroundLocationMonitor.swift`, `Marauders/Presentation/Upload/UploadVideoViewModel.swift`, `MaraudersTests/UploadVideoViewModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // BackgroundExecution.swift
  @MainActor enum BackgroundExecution {
      /// Asks iOS for time to finish what is running (about 30 seconds once the app leaves the screen). Answers how to give it
      /// back; calling that twice is harmless. If the time runs out first, the task is ended and nothing else happens.
      static func begin(_ name: String) -> @MainActor () -> Void
  }
  // UploadVideoViewModel.init gains, after audioInspector:
  //   holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundExecution.begin
  ```

- [ ] **Step 1: Write the failing tests.**
  - `BackgroundExecutionTests.releasingTwiceIsHarmless`: `let release = BackgroundExecution.begin("test"); release(); release()` (the unit tests run inside the app, so `UIApplication.shared` exists).
  - In `UploadVideoViewModelTests`, with `holdAwake: { name in holds.begun.append(name); return { holds.released += 1 } }` on `makeViewModel` (add the parameter to the helper): `theUploadHoldsABackgroundTaskUntilItEnds` (while the double holds the upload `holds.begun == ["Upload video"]` and `holds.released == 0`; after success `holds.released == 1`); `theTaskIsReleasedOnceWhenTheUploadFails` (a failing repository: `begun.count == 1`, `released == 1`); `theTaskIsReleasedOnceWhenTheUploadIsCancelled` (a double that sleeps until it is cancelled and then throws `CancellationError`; cancel the task running `upload()`: `released == 1`); `aTapThatStartsNothingHoldsNoTask` (no file, then a file without a location: `begun.isEmpty`).
- [ ] **Step 2: Run** `BackgroundExecutionTests`, `UploadVideoViewModelTests`. Expected: the build fails with `cannot find 'BackgroundExecution' in scope`.
- [ ] **Step 3: Implement.** Move `BackgroundLocationMonitor.beginBackgroundTask` and the private `BackgroundTask` class into `BackgroundExecution.swift` as `BackgroundExecution.begin` and a private `BackgroundTask` (same code, same expiration handler); the monitor's default `holdAwake` becomes `BackgroundExecution.begin` and its two private pieces are deleted. In `UploadVideoViewModel`, store `holdAwake`; in `upload()`, after the two guards and before `isUploading = true`: `let release = holdAwake("Upload video")` and `defer { release() }`.
- [ ] **Step 4: Run** `BackgroundExecutionTests`, `UploadVideoViewModelTests`, `BackgroundLocationMonitorTests`, `AppCoordinatorTests`. Expected: all pass, and the monitor tests needed no edit.
- [ ] **Step 5: Commit:** `git add Marauders-ios/Marauders/Presentation/Common/BackgroundExecution.swift Marauders-ios/Marauders/Presentation/Map/BackgroundLocationMonitor.swift Marauders-ios/Marauders/Presentation/Upload/UploadVideoViewModel.swift Marauders-ios/MaraudersTests/BackgroundExecutionTests.swift Marauders-ios/MaraudersTests/UploadVideoViewModelTests.swift` → "Hold a background task while a clip uploads and share the helper with the location monitor".

### Task 7: Documentation and whole-branch verification

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Update `ARCHITECTURE.md`.**
  - "Upload path (client)": append that the export file is copied into the multipart body in 1 MiB chunks (`MultipartBodyWriter`), so a clip is never held whole in memory; that `UploadVideoViewModel` shows how much of the body has been sent (`Uploading… 42%`, then `Finishing…` until the Worker answers); and that it holds a `beginBackgroundTask` for the whole upload, which gives the transfer about 30 seconds if the viewer leaves the app (a longer absence still ends the connection and the viewer sees the existing error).
  - The `@concurrent` bullet: replace "the multipart body writer of `URLSessionHTTPClient`" with "`MultipartBodyWriter`".
  - The "MVVM flow (upload)" diagram: `Up->>Repo: upload(fileURL:mimeType:progress:)` and a line `API-->>VM: progress 0…1 while the body is sent`.
  - The staging table row "Multipart body": the clip is copied into it in 1 MiB chunks.
- [ ] **Step 2: Check the branch.** `git diff --stat main...HEAD` lists only the files this plan names; `git diff main...HEAD -- Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` shows changes in the `upload` function only; `grep -rn "Data(contentsOf" Marauders-ios/Marauders/Data/API/VideoUploadAPIClient.swift` prints nothing.
- [ ] **Step 3: Run the whole unit target** (`-only-testing:MaraudersTests`). Expected: `** TEST SUCCEEDED **`; write down the total (1026 plus this work's new tests) and the number of suites.
- [ ] **Step 4: Run the checkers.** `sh Marauders-ios/Scripts/check-layers.sh` prints nothing; `xcrun swift-format lint` over every Swift file the branch touched prints nothing.
- [ ] **Step 5: Run the unsigned Release archive.** Expected: `** ARCHIVE SUCCEEDED **` and no error lines.
- [ ] **Step 6: Run the UI target once**, detached (see "How to run things"). Expected: 51 of 52, the one red being the known simulator-only comment-language test.
- [ ] **Step 7: Commit:** `git add ARCHITECTURE.md` → "Document the streamed, progress-reporting upload path".

## After the last task (the owner's calls, not tasks)

- **Merge into `main`.** It needs the owner's yes and their `RetryingHTTPClient.swift` edit committed or stashed first. Re-run the unit target on the merged tree, and the UI target and the Release archive too when that tree is not the branch's tree.
- **Push** and a **TestFlight build** (Jenkins "Build Now" is the owner's; a push builds nothing).
- **A phone check of cut 1**, only if the owner asks (the spec's Verification): leave the app for 5 seconds and for 60 seconds during an upload, and lock the phone; the short absence is expected to finish and the long one to fail with the existing error. A device upload creates a real clip in the live feed (use a short clip and delete it from Profile), so it is the owner's call.
- **The plan for cut 2** is written after cut 1 has landed and its phone results are in.
