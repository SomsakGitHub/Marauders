//
//  UploadVideoViewModelUploadTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The Upload tab as a view of the uploader: what a tap hands over, what the uploader's snapshots turn into on screen,
/// and the one time a finished clip is reported to the feed.
@MainActor
struct UploadVideoViewModelUploadTests {
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!
    private static let uploadedClip = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
    private static let interrupted = "The upload was interrupted. Try again."
    private static let bodyGone = "The clip is no longer on this iPhone. Choose the video again."

    private struct Inspector: ClipAudioInspecting {
        let result: ClipAudioAssessment
        func inspect(fileURL: URL) async -> ClipAudioAssessment { result }
    }

    private func makeViewModel(
        exporter: VideoExporting = StubVideoExporter(result: .failure(StubError.exportFailed)),
        uploader: FakeClipUploader = FakeClipUploader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector(),
        holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    ) -> UploadVideoViewModel {
        UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: exporter),
            uploads: ClipUploadUseCases(uploader: uploader),
            audioInspector: audioInspector,
            holdAwake: holdAwake
        )
    }

    /// A model with a clip and a place, ready for a tap on Upload.
    private func makeUploadReadyViewModel(
        uploader: FakeClipUploader = FakeClipUploader(),
        holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    ) throws -> UploadVideoViewModel {
        let model = makeViewModel(uploader: uploader, holdAwake: holdAwake)
        model.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        model.applyClipLocation(Self.bangkok)
        return model
    }

    /// The loop the root view runs for as long as the app lives.
    private func observing(_ model: UploadVideoViewModel) -> Task<Void, Never> {
        Task { await model.observeUploads() }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The tap

    @Test func theRequestCarriesTheSpeechCheckTheCaptionAndNoLanguage() async throws {
        // Each viewer's iPhone works out the language when they listen, so the uploader neither names nor detects it.
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let uploader = FakeClipUploader()
        let model = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)), uploader: uploader,
            audioInspector: Inspector(result: .init(content: .speech, signal: .detected)))
        model.applyClipLocation(Self.bangkok)
        await model.prepare(sourceURL: source)
        model.caption = "Sunset over Bangkok"
        #expect(model.audioAssessment?.content == .speech)
        #expect(model.audioAssessment?.spokenLanguage == nil)
        #expect(model.canUpload)

        await model.upload()

        let request = try #require(uploader.started.first)
        #expect(uploader.started.count == 1)
        #expect(request.fileURL == mp4)
        #expect(request.mimeType == "video/mp4")
        #expect(request.clipLocation == Self.bangkok)
        #expect(request.caption == "Sunset over Bangkok")
        #expect(request.audioAssessment?.content == .speech)
        #expect(request.audioAssessment?.spokenLanguage == nil)
    }

    @Test func startingClearsTheFormAndDeletesTheExportedFile() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)),
            audioInspector: Inspector(result: .init(content: .speech, signal: .detected)))
        model.applyClipLocation(Self.bangkok)
        await model.prepare(sourceURL: source)
        model.caption = "Sunset over Bangkok"
        try #require(FileManager.default.fileExists(atPath: mp4.path))
        try #require(model.audioAssessment != nil)

        await model.upload()

        #expect(model.uploadFileURL == nil)
        #expect(model.caption == "")
        #expect(model.audioAssessment == nil)
        #expect(!FileManager.default.fileExists(atPath: mp4.path))
        // Nothing says the clip is stored until the Worker has answered.
        #expect(!model.isSuccess)
        #expect(model.statusMessage == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theButtonStaysDisabledBetweenStartAndTheFirstSnapshot() async throws {
        let uploader = FakeClipUploader()
        let model = try makeUploadReadyViewModel(uploader: uploader)

        await model.upload()

        // The uploader has taken the clip on and has not said anything yet.
        #expect(uploader.started.count == 1)
        #expect(model.isUploading)
        #expect(!model.canUpload)
        #expect(model.uploadProgress == 0)
        #expect(model.uploadProgressLabel == "Uploading… 0%")

        // Its first snapshot takes over from there.
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.uploading(fraction: 0.25))
        await waitUntil { model.uploadProgress == 0.25 }
        #expect(model.uploadProgress == 0.25)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSnapshotThatArrivesBeforeStartReturnsIsNotOverwritten() async throws {
        let gate = SignOutGate()
        let uploader = FakeClipUploader()
        uploader.startGate = gate
        let model = try makeUploadReadyViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        let tap = Task { await model.upload() }
        await waitUntil { uploader.started.count == 1 }
        // The uploader can be quicker than its own start call.
        uploader.emit(.uploading(fraction: 0.4))
        await waitUntil { model.uploadProgress == 0.4 }
        await gate.open()
        await tap.value

        #expect(model.isUploading)
        #expect(model.uploadProgress == 0.4)
    }

    @Test func aStartThatFailsShowsItsMessageAndKeepsTheFile() async throws {
        let uploader = FakeClipUploader()
        uploader.startError = ClipUploadError.notEnoughSpace
        let model = try makeUploadReadyViewModel(uploader: uploader)
        let file = try #require(model.uploadFileURL)
        defer { try? FileManager.default.removeItem(at: file) }
        model.caption = "Sunset over Bangkok"

        await model.upload()

        #expect(model.statusMessage == "Not enough free space on this iPhone to upload the clip")
        #expect(!model.isSuccess)
        #expect(!model.isUploading)
        #expect(model.uploadProgress == nil)
        #expect(model.uploadFileURL == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(model.caption == "Sunset over Bangkok")
        #expect(model.canUpload, "the viewer can tap again")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondTapWhileUploadingStartsNothing() async throws {
        // The button is disabled while uploading, yet two taps can overlap (a double tap while the clip is staged).
        let gate = SignOutGate()
        let uploader = FakeClipUploader()
        uploader.startGate = gate
        let holds = BackgroundHolds()
        let model = try makeUploadReadyViewModel(uploader: uploader, holdAwake: { holds.begin($0) })

        let first = Task { await model.upload() }
        await waitUntil { uploader.started.count == 1 }
        #expect(model.isUploading)

        await model.upload()

        #expect(uploader.started.count == 1)
        #expect(holds.begun.count == 1)

        await gate.open()
        await first.value
        #expect(uploader.started.count == 1)
        #expect(holds.released == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func canUploadIsFalseWhileAnUploadRuns() async throws {
        // An upload the app did not start this time (it began before a relaunch) is told by the uploader.
        let uploader = FakeClipUploader()
        let model = try makeUploadReadyViewModel(uploader: uploader)
        #expect(model.canUpload)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.uploading(fraction: 0.5))
        await waitUntil { model.isUploading }

        #expect(model.isUploading)
        #expect(!model.canUpload)
    }

    // MARK: - Progress

    @Test(.timeLimit(.minutes(1)))
    func theLabelRoundsDownAndEndsWithTheUpload() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.uploading(fraction: 0.425))
        await waitUntil { model.uploadProgressLabel == "Uploading… 42%" }
        #expect(model.uploadProgressLabel == "Uploading… 42%")
        uploader.emit(.uploading(fraction: 0.999))
        await waitUntil { model.uploadProgressLabel == "Uploading… 99%" }
        #expect(model.uploadProgressLabel == "Uploading… 99%")

        uploader.emit(.finished(Self.uploadedClip))
        await waitUntil { !model.isUploading }
        #expect(model.uploadProgress == nil)
        #expect(model.uploadProgressLabel == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func allBytesSentShowsFinishingNotOneHundredPercent() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.uploading(fraction: 0.999))
        await waitUntil { model.isUploading }
        #expect(!model.isFinishingUpload)

        uploader.emit(.finishing)
        await waitUntil { model.isFinishingUpload }

        #expect(model.isUploading)
        #expect(model.isFinishingUpload)
        #expect(model.uploadProgress == 1)
        #expect(model.uploadProgressLabel == "Finishing…")
        #expect(model.uploadProgressLabel?.contains("100") == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFractionOutsideTheRangeIsClamped() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.uploading(fraction: 1.7))
        await waitUntil { model.uploadProgress == 1 }
        #expect(model.uploadProgress == 1)
        #expect(model.uploadProgressLabel == "Finishing…", "a fraction of 1 is never shown as 100%")

        uploader.emit(.uploading(fraction: -0.3))
        await waitUntil { model.uploadProgress == 0 }
        #expect(model.uploadProgress == 0)
        #expect(model.uploadProgressLabel == "Uploading… 0%")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFractionThatIsNotANumberChangesNothing() async throws {
        // min and max cannot clamp NaN, and `Int(.nan)` in the label would trap.
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.uploading(fraction: 0.5))
        await waitUntil { model.uploadProgress == 0.5 }
        try #require(model.uploadProgress == 0.5)

        uploader.emit(.uploading(fraction: .nan))
        await UploaderKit.settle()

        #expect(model.isUploading)
        #expect(model.uploadProgress == 0.5)
        #expect(model.uploadProgressLabel == "Uploading… 50%")

        // The loop still reads: a number after the one that was not a number gets through.
        uploader.emit(.uploading(fraction: 0.75))
        await waitUntil { model.uploadProgress == 0.75 }
        #expect(model.uploadProgress == 0.75)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSnapshotThatRestartsAtZeroLowersTheBar() async throws {
        // A 401 after the whole body went out makes the uploader send the clip again from 0.
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.finishing)
        await waitUntil { model.isFinishingUpload }
        uploader.emit(.uploading(fraction: 0.1))
        await waitUntil { model.uploadProgress == 0.1 }

        #expect(model.uploadProgress == 0.1)
        #expect(!model.isFinishingUpload)
    }

    // MARK: - Safety net

    @Test(.timeLimit(.minutes(1)))
    func theSafetyNetCoversStagingAndIsReleasedWhenItEnds() async throws {
        let gate = SignOutGate()
        let uploader = FakeClipUploader()
        uploader.startGate = gate
        let holds = BackgroundHolds()
        let model = try makeUploadReadyViewModel(uploader: uploader, holdAwake: { holds.begin($0) })
        let tap = Task { await model.upload() }
        await waitUntil { uploader.started.count == 1 }

        // The clip is still being handed over, and the hold has been in place since the tap.
        #expect(holds.begun == ["Upload video"])
        #expect(holds.released == 0)

        await gate.open()
        await tap.value

        #expect(holds.begun == ["Upload video"])
        #expect(holds.released == 1)
    }

    @Test func theSafetyNetCoversStagingAndIsReleasedWhenStartFails() async throws {
        let uploader = FakeClipUploader()
        uploader.startError = StubError.uploadFailed
        let holds = BackgroundHolds()
        let model = try makeUploadReadyViewModel(uploader: uploader, holdAwake: { holds.begin($0) })

        await model.upload()

        #expect(model.statusMessage == "upload failed")
        #expect(holds.begun == ["Upload video"])
        #expect(holds.released == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theSafetyNetCoversStagingAndIsReleasedWhenTheTapIsCancelled() async throws {
        let gate = SignOutGate()
        let uploader = FakeClipUploader()
        uploader.startGate = gate
        // What a start that notices the cancellation throws once it looks.
        uploader.startError = CancellationError()
        let holds = BackgroundHolds()
        let model = try makeUploadReadyViewModel(uploader: uploader, holdAwake: { holds.begin($0) })
        let tap = Task { await model.upload() }
        await waitUntil { uploader.started.count == 1 }
        #expect(holds.begun.count == 1)
        #expect(holds.released == 0)

        tap.cancel()
        await gate.open()
        await tap.value

        #expect(holds.released == 1)
        #expect(!model.isUploading)
        #expect(model.uploadFileURL != nil, "nothing took the clip")
    }

    @Test func aTapThatStartsNothingHoldsNoTask() async throws {
        let holds = BackgroundHolds()
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader, holdAwake: { holds.begin($0) })

        await model.upload()
        model.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        await model.upload()

        #expect(model.statusMessage == "Set the clip location before uploading")
        #expect(uploader.started.isEmpty)
        #expect(holds.begun.isEmpty)
        #expect(holds.released == 0)
    }

    // MARK: - A failure

    @Test(.timeLimit(.minutes(1)))
    func aFailureShowsItsMessageAndTheButtonsItAllows() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }

        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.failedUpload != nil }

        #expect(model.failedUpload == .init(message: Self.interrupted, canRetry: true))
        #expect(model.statusMessage == Self.interrupted)
        #expect(!model.isSuccess)
        #expect(!model.isUploading)
        #expect(model.uploadProgress == nil)

        // The body is gone, so only Choose another video is left.
        uploader.emit(.failed(message: Self.bodyGone, canRetry: false))
        await waitUntil { model.failedUpload?.canRetry == false }

        #expect(model.failedUpload == .init(message: Self.bodyGone, canRetry: false))
        #expect(model.statusMessage == Self.bodyGone)
        #expect(!model.isSuccess)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewAttemptClearsTheFailureMessage() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.statusMessage == Self.interrupted }
        try #require(model.statusMessage == Self.interrupted)

        // Try again: the uploader goes back to sending.
        uploader.emit(.uploading(fraction: 0))
        await waitUntil { model.isUploading }
        #expect(model.failedUpload == nil)
        #expect(model.statusMessage == nil)

        // The same when the retry answers all at once with every byte sent.
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.statusMessage == Self.interrupted }
        uploader.emit(.finishing)
        await waitUntil { model.isFinishingUpload }
        #expect(model.failedUpload == nil)
        #expect(model.statusMessage == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailureThatIsGoneTakesItsMessageWithIt() async throws {
        // The upload was discarded (a sign out, say): the uploader has nothing left, and so has the screen.
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.statusMessage == Self.interrupted }
        try #require(model.statusMessage == Self.interrupted)

        uploader.emit(.idle)
        await waitUntil { model.failedUpload == nil }

        #expect(model.failedUpload == nil)
        #expect(model.statusMessage == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewAttemptLeavesAStatusLineAboutSomethingElseAlone() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.failedUpload != nil }
        model.statusMessage = "Couldn’t read location — try again"

        uploader.emit(.uploading(fraction: 0))
        await waitUntil { model.isUploading }

        #expect(model.statusMessage == "Couldn’t read location — try again")
    }

    @Test(.timeLimit(.minutes(1)))
    func tryAgainAsksTheUploaderToRetry() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.failedUpload != nil }

        await model.retryUpload()

        #expect(uploader.retries == 1)
        #expect(uploader.discards == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func chooseAnotherVideoDiscardsTheUploadAndResetsTheForm() async throws {
        let uploader = FakeClipUploader()
        let model = try makeUploadReadyViewModel(uploader: uploader)
        let file = try #require(model.uploadFileURL)
        defer { try? FileManager.default.removeItem(at: file) }
        model.caption = "Sunset over Bangkok"
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.bodyGone, canRetry: false))
        await waitUntil { model.failedUpload != nil }

        await model.chooseAnotherVideo()

        #expect(uploader.discards == 1)
        #expect(model.uploadFileURL == nil)
        #expect(model.clipLocation == nil)
        #expect(model.caption == "")
        #expect(model.audioAssessment == nil)
        #expect(model.statusMessage == nil)
        #expect(!model.isSuccess)
    }

    @Test(.timeLimit(.minutes(1)))
    func pickingAnotherVideoDiscardsAFailedUpload() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let uploader = FakeClipUploader()
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)), uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.failed(message: Self.interrupted, canRetry: true))
        await waitUntil { model.failedUpload != nil }

        await model.prepare(sourceURL: source)

        #expect(uploader.discards == 1)
        #expect(model.uploadFileURL == mp4)
        #expect(!model.isPreparing)
    }

    @Test(.timeLimit(.minutes(1)))
    func pickingAVideoWhenNothingFailedDiscardsNothing() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let uploader = FakeClipUploader()
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)), uploader: uploader)
        let observer = observing(model)
        defer { observer.cancel() }
        uploader.emit(.uploading(fraction: 0.5))
        await waitUntil { model.isUploading }

        await model.prepare(sourceURL: source)

        #expect(uploader.discards == 0, "an upload that is still running is not the picker's to drop")
        #expect(model.uploadFileURL == mp4)
    }

    // MARK: - A finished upload

    @Test(.timeLimit(.minutes(1)))
    func aFinishedUploadIsReportedOnceWhenTheAppIsActive() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let reported = ReportedClips(uploader: uploader)
        model.onUploaded = { reported.record($0) }
        let observer = observing(model)
        defer { observer.cancel() }
        model.setAppActive(true)

        uploader.emit(.finished(Self.uploadedClip))
        await waitUntil { reported.videos.count == 1 }

        #expect(reported.videos.map(\.id) == [Self.uploadedClip.id])
        #expect(uploader.discards == 1)
        #expect(reported.discardsSeen == [1], "the record is deleted before the feed is told")
        #expect(model.isSuccess)
        #expect(model.statusMessage == "Upload complete — opening feed")

        // The same snapshot again changes nothing. The snapshot after it proves the loop has read both.
        uploader.emit(.finished(Self.uploadedClip))
        uploader.emit(.uploading(fraction: 0.3))
        await waitUntil { model.uploadProgress == 0.3 }
        #expect(reported.videos.count == 1)
        #expect(uploader.discards == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFinishedUploadWaitsForTheAppToBecomeActive() async throws {
        let uploader = FakeClipUploader()
        let model = makeViewModel(uploader: uploader)
        let reported = ReportedClips(uploader: uploader)
        model.onUploaded = { reported.record($0) }
        let observer = observing(model)
        defer { observer.cancel() }
        model.setAppActive(false)

        // The upload ends while the app is not on screen: the loop has read it once the bar is gone.
        uploader.emit(.uploading(fraction: 0.5))
        await waitUntil { model.isUploading }
        uploader.emit(.finished(Self.uploadedClip))
        await waitUntil { !model.isUploading }
        await UploaderKit.settle()

        #expect(reported.videos.isEmpty)
        #expect(uploader.discards == 0, "a clip nobody has seen is not given up")
        #expect(!model.isSuccess)
        #expect(model.statusMessage == nil)

        model.setAppActive(true)
        await waitUntil { reported.videos.count == 1 }

        #expect(reported.videos.map(\.id) == [Self.uploadedClip.id])
        #expect(uploader.discards == 1)
        #expect(reported.discardsSeen == [1])
        #expect(model.isSuccess)
        #expect(model.statusMessage == "Upload complete — opening feed")

        // Leaving the app and coming back reports nothing more.
        model.setAppActive(false)
        model.setAppActive(true)
        await UploaderKit.settle()
        #expect(reported.videos.count == 1)
        #expect(uploader.discards == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theFeedIsToldOnlyOnceTheRecordIsDeleted() async throws {
        let gate = SignOutGate()
        let uploader = FakeClipUploader()
        uploader.discardGate = gate
        let log = EventLog()
        uploader.onDiscard = { log.record("discard asked") }
        let model = makeViewModel(uploader: uploader)
        model.onUploaded = { _ in log.record("feed told") }
        let observer = observing(model)
        defer { observer.cancel() }
        model.setAppActive(true)

        uploader.emit(.finished(Self.uploadedClip))
        await waitUntil { uploader.discards == 1 }
        await UploaderKit.settle()

        // The delete is still under way, so the feed has not been told.
        #expect(log.events == ["discard asked"])

        await gate.open()
        await waitUntil { log.events.count == 2 }

        #expect(log.events == ["discard asked", "feed told"])
    }

    // MARK: - Doubles

    /// Records the background tasks the view model begins and how many it gives back.
    @MainActor
    private final class BackgroundHolds {
        private(set) var begun: [String] = []
        private(set) var released = 0

        func begin(_ name: String) -> @MainActor () -> Void {
            begun.append(name)
            return { [self] in released += 1 }
        }
    }

    /// What happened, in order, written from the uploader's hook and from the view model's callback.
    nonisolated final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func record(_ event: String) {
            lock.withLock { recorded.append(event) }
        }

        var events: [String] { lock.withLock { recorded } }
    }

    /// Records the clips the view model reports to the feed, and how often the uploader had been asked to discard at
    /// each report.
    @MainActor
    private final class ReportedClips {
        private let uploader: FakeClipUploader
        private(set) var videos: [FeedVideo] = []
        private(set) var discardsSeen: [Int] = []

        init(uploader: FakeClipUploader) {
            self.uploader = uploader
        }

        func record(_ video: FeedVideo) {
            videos.append(video)
            discardsSeen.append(uploader.discards)
        }
    }
}
