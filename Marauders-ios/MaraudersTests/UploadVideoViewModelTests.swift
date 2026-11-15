//
//  UploadVideoViewModelTests.swift
//  MaraudersTests
//

import CoreLocation
import Foundation
import Testing

@testable import Marauders

@MainActor
struct UploadVideoViewModelTests {
    private struct Inspector: ClipAudioInspecting {
        let result: ClipAudioAssessment
        func inspect(fileURL: URL) async -> ClipAudioAssessment { result }
    }
    @Test func uploadSendsTheSpeechCheckButNeverALanguage() async throws {
        // Each viewer's iPhone works out the language when they listen, so the uploader neither names nor detects it.
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let repository = AssessmentRecordingRepository()
        let model = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)), uploadRepository: repository,
            audioInspector: Inspector(result: .init(content: .speech, signal: .detected)))
        model.applyClipLocation(Self.bangkok)
        await model.prepare(sourceURL: source)
        #expect(model.audioAssessment?.content == .speech)
        #expect(model.audioAssessment?.spokenLanguage == nil)
        #expect(model.canUpload)

        await model.upload()

        #expect(repository.uploadedAssessment?.content == .speech)
        #expect(repository.uploadedAssessment?.spokenLanguage == nil)
    }
    @Test func withoutAnInspectorTheViewModelDoesNotAnalyseTheAudioItself() async throws {
        // The real inspector is a Data type, so the composition root hands it in. A view model made without one has
        // none: the real inspector reports this tone as detected.
        let clip = try TestFixtureFiles.temporaryToneFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        let model = UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: StubVideoExporter(result: .success(clip))),
            uploadVideo: UploadFeedVideoUseCase(
                repository: RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))))
        await model.prepare(sourceURL: clip)
        #expect(model.audioAssessment?.signal == .unknown)
    }
    @Test func quietAudioWarningDoesNotBlockUploadAndResetClearsIt() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)),
            audioInspector: Inspector(result: .init(signal: .quietSamples)))
        model.applyClipLocation(Self.bangkok)
        await model.prepare(sourceURL: source)
        #expect(model.audioAssessment?.signal == .quietSamples)
        #expect(model.canUpload)
        #expect(model.statusMessage == nil)
        model.resetPickedFile()
        #expect(model.audioAssessment == nil)
        #expect(!model.canUpload)
    }
    @Test func resetDuringAudioInspectionCannotRestoreDiscardedFile() async throws {
        // A class, not an actor: Swift 6.4 does not let an actor conform to this MainActor-isolated protocol.
        final class DeferredInspector: ClipAudioInspecting, @unchecked Sendable {
            var continuation: CheckedContinuation<ClipAudioAssessment, Never>?
            var waiter: CheckedContinuation<Void, Never>?
            func inspect(fileURL: URL) async -> ClipAudioAssessment {
                await withCheckedContinuation {
                    continuation = $0; waiter?.resume(); waiter = nil
                }
            }
            func waitUntilInspecting() async {
                if continuation != nil { return }; await withCheckedContinuation { waiter = $0 }
            }
            func finish() { continuation?.resume(returning: .init(signal: .detected)); continuation = nil }
        }
        let inspector = DeferredInspector()
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)), audioInspector: inspector)
        let task = Task { await model.prepare(sourceURL: source) }
        await inspector.waitUntilInspecting()
        #expect(model.isCheckingAudio)
        model.resetPickedFile()
        inspector.finish()
        await task.value
        #expect(model.uploadFileURL == nil)
        #expect(model.audioAssessment == nil)
        #expect(!model.isPreparing)
        #expect(!FileManager.default.fileExists(atPath: mp4.path))
    }

    private final class AssessmentRecordingRepository: VideoUploadRepository, @unchecked Sendable {
        private(set) var uploadedAssessment: ClipAudioAssessment?
        func upload(
            fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
            audioAssessment: ClipAudioAssessment?
        ) async throws -> FeedVideo {
            uploadedAssessment = audioAssessment
            return FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        }
        func upload(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String) async throws
            -> FeedVideo
        {
            try await upload(
                fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption, audioAssessment: nil
            )
        }
    }

    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    private func makeViewModel(
        exporter: VideoExporting = StubVideoExporter(result: .failure(StubError.exportFailed)),
        uploadRepository: VideoUploadRepository = RecordingVideoUploadRepository(
            result: .failure(StubError.uploadFailed)),
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector()
    ) -> UploadVideoViewModel {
        UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: exporter),
            uploadVideo: UploadFeedVideoUseCase(repository: uploadRepository),
            locationManager: locationManager,
            videoLocationReader: videoLocationReader,
            audioInspector: audioInspector
        )
    }

    @Test func canUploadRequiresFileAndLocation() throws {
        let viewModel = makeViewModel()
        #expect(viewModel.canUpload == false)

        viewModel.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        #expect(viewModel.canUpload == false)

        viewModel.applyClipLocation(Self.bangkok)
        #expect(viewModel.canUpload)
    }

    @Test func canUploadIsFalseWhileUploading() throws {
        let viewModel = makeViewModel()
        viewModel.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        viewModel.applyClipLocation(Self.bangkok)
        #expect(viewModel.canUpload)

        viewModel.isUploading = true
        #expect(viewModel.canUpload == false)
    }

    @Test func prepareSuccessStoresUploadFileAndClearsStatus() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let exporter = RecordingVideoExporter(result: .success(mp4))
        let viewModel = makeViewModel(exporter: exporter)

        await viewModel.prepare(sourceURL: source)

        #expect(viewModel.uploadFileURL == mp4)
        #expect(exporter.lastSourceURL == source)
        #expect(viewModel.statusMessage == nil)
        #expect(viewModel.isPreparing == false)
        #expect(viewModel.isSuccess == false)
    }

    @Test func prepareFailureSurfacesErrorAndClearsUploadFile() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let viewModel = makeViewModel(exporter: StubVideoExporter(result: .failure(StubError.exportFailed)))

        await viewModel.prepare(sourceURL: source)

        #expect(viewModel.uploadFileURL == nil)
        #expect(viewModel.statusMessage == "export failed")
        #expect(viewModel.isSuccess == false)
        #expect(viewModel.isPreparing == false)
    }

    @Test func prepareSuggestsClipLocationFromVideoMetadata() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let viewModel = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)),
            videoLocationReader: StubVideoLocationReader(location: Self.bangkok)
        )

        await viewModel.prepare(sourceURL: source)

        #expect(viewModel.clipLocation == Self.bangkok)
    }

    @Test func prepareKeepsManualLocationWhenVideoHasNoMetadata() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let manual = ClipLocation(latitude: 1.5, longitude: 2.5)!
        let viewModel = makeViewModel(
            exporter: RecordingVideoExporter(result: .success(mp4)),
            videoLocationReader: StubVideoLocationReader(location: nil)
        )
        viewModel.applyClipLocation(manual)

        await viewModel.prepare(sourceURL: source)

        #expect(viewModel.clipLocation == manual)
    }

    @Test func uploadWithoutFileIsIgnored() async {
        let repository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))
        let viewModel = makeViewModel(uploadRepository: repository)

        await viewModel.upload()

        #expect(viewModel.statusMessage == nil)
        #expect(viewModel.isUploading == false)
        #expect(repository.uploadCount == 0)
    }

    @Test func uploadWithoutClipLocationPromptsUser() async throws {
        let repository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))
        let viewModel = makeViewModel(uploadRepository: repository)
        viewModel.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)

        await viewModel.upload()

        #expect(viewModel.statusMessage == "Set the clip location before uploading")
        #expect(viewModel.isSuccess == false)
        #expect(repository.uploadCount == 0)
    }

    @Test func uploadSuccessMarksSuccessAndRequestsFeedReload() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let repository = RecordingVideoUploadRepository(result: .success(video))
        let viewModel = makeViewModel(uploadRepository: repository)
        viewModel.uploadFileURL = file
        viewModel.applyClipLocation(Self.bangkok)

        let callback = CallbackFlag()
        viewModel.onUploaded = { uploaded in
            callback.wasCalled = true
            callback.uploadedID = uploaded.id
        }

        await viewModel.upload()

        #expect(viewModel.isSuccess)
        #expect(viewModel.statusMessage == "Upload complete — opening feed")
        #expect(viewModel.uploadFileURL == nil)
        #expect(repository.uploadedFileURL == file)
        #expect(repository.uploadedMimeType == "video/mp4")
        #expect(repository.uploadedClipLocation == Self.bangkok)
        #expect(callback.wasCalled)
        #expect(callback.uploadedID == video.id)
    }

    @Test func uploadFailureSurfacesErrorAndKeepsFile() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let repository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))
        let viewModel = makeViewModel(uploadRepository: repository)
        viewModel.uploadFileURL = file
        viewModel.applyClipLocation(Self.bangkok)

        await viewModel.upload()

        #expect(viewModel.isSuccess == false)
        #expect(viewModel.statusMessage == "upload failed")
        #expect(viewModel.isUploading == false)
        #expect(viewModel.uploadFileURL == file)
    }

    @Test func applyClipLocationClearsStatus() {
        let viewModel = makeViewModel()
        viewModel.statusMessage = "old error"

        viewModel.applyClipLocation(Self.bangkok)

        #expect(viewModel.clipLocation == Self.bangkok)
        #expect(viewModel.statusMessage == nil)
    }

    @Test func resetPickedFileClearsState() throws {
        let viewModel = makeViewModel()
        viewModel.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        viewModel.applyClipLocation(Self.bangkok)
        viewModel.statusMessage = "done"
        viewModel.isSuccess = true

        viewModel.resetPickedFile()

        #expect(viewModel.uploadFileURL == nil)
        #expect(viewModel.clipLocation == nil)
        #expect(viewModel.statusMessage == nil)
        #expect(viewModel.isSuccess == false)
    }

    @Test func clipLocationWhenAuthorizedRequestsFixImmediately() {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let viewModel = makeViewModel(locationManager: locationManager)

        viewModel.setClipLocationFromCurrentPositionTapped()

        #expect(viewModel.isResolvingClipLocation)
        #expect(locationManager.locationRequestCount == 1)
        #expect(locationManager.authorizationRequestCount == 0)
        #expect(viewModel.showClipLocationPrePrompt == false)
        #expect(viewModel.showClipLocationDeniedAlert == false)
    }

    @Test func clipLocationWhenDeniedShowsAlertWithoutRequesting() {
        let locationManager = FakeLocationManager(authorizationStatus: .denied)
        let viewModel = makeViewModel(locationManager: locationManager)

        viewModel.setClipLocationFromCurrentPositionTapped()

        #expect(viewModel.showClipLocationDeniedAlert)
        #expect(viewModel.isResolvingClipLocation == false)
        #expect(locationManager.locationRequestCount == 0)
        #expect(locationManager.authorizationRequestCount == 0)
    }

    @Test func clipLocationWhenNotDeterminedShowsPrePrompt() {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = makeViewModel(locationManager: locationManager)

        viewModel.setClipLocationFromCurrentPositionTapped()

        #expect(viewModel.showClipLocationPrePrompt)
        #expect(locationManager.authorizationRequestCount == 0)
        #expect(locationManager.locationRequestCount == 0)
    }

    @Test func confirmingPrePromptRequestsSystemAuthorization() {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = makeViewModel(locationManager: locationManager)
        viewModel.setClipLocationFromCurrentPositionTapped()

        viewModel.confirmClipLocationPermissionRequest()

        #expect(viewModel.showClipLocationPrePrompt == false)
        #expect(locationManager.authorizationRequestCount == 1)
    }

    @Test func cancellingPrePromptDoesNotRequestAuthorization() {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = makeViewModel(locationManager: locationManager)
        viewModel.setClipLocationFromCurrentPositionTapped()

        viewModel.cancelClipLocationPermissionRequest()

        #expect(viewModel.showClipLocationPrePrompt == false)
        #expect(locationManager.authorizationRequestCount == 0)
    }

    @Test func authorizationGrantedAfterPromptRequestsFix() async {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = makeViewModel(locationManager: locationManager)
        viewModel.setClipLocationFromCurrentPositionTapped()
        viewModel.confirmClipLocationPermissionRequest()

        locationManager.authorizationStatus = .authorizedWhenInUse
        locationManager.simulateAuthorizationChange()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(locationManager.locationRequestCount == 1)
        #expect(viewModel.isResolvingClipLocation)
    }

    @Test func authorizationDeniedAfterPromptShowsAlert() async {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = makeViewModel(locationManager: locationManager)
        viewModel.setClipLocationFromCurrentPositionTapped()
        viewModel.confirmClipLocationPermissionRequest()

        locationManager.authorizationStatus = .denied
        locationManager.simulateAuthorizationChange()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(viewModel.showClipLocationDeniedAlert)
        #expect(locationManager.locationRequestCount == 0)
    }

    @Test func receivedLocationSetsClipLocation() async {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let viewModel = makeViewModel(locationManager: locationManager)
        viewModel.setClipLocationFromCurrentPositionTapped()
        #expect(viewModel.isResolvingClipLocation)

        locationManager.simulateLocations([CLLocation(latitude: 13.7563, longitude: 100.5018)])
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(viewModel.clipLocation == Self.bangkok)
        #expect(viewModel.isResolvingClipLocation == false)
        #expect(viewModel.statusMessage == nil)
    }

    // MARK: - Upload progress

    private static let uploadedClip = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)

    /// A model with a clip and a place, ready for a tap on Upload.
    private func makeUploadReadyViewModel(_ repository: VideoUploadRepository) throws -> UploadVideoViewModel {
        let model = makeViewModel(uploadRepository: repository)
        model.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        model.applyClipLocation(Self.bangkok)
        return model
    }

    @Test func theBarStartsAtZeroWhenTheUploadStarts() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()

        #expect(model.isUploading)
        #expect(model.uploadProgress == 0)
        #expect(model.uploadProgressLabel == "Uploading… 0%")

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
    }

    @Test func theLabelRoundsDownAndEndsWithTheUpload() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()

        await repository.report(0.425)
        #expect(model.uploadProgressLabel == "Uploading… 42%")
        await repository.report(0.999)
        #expect(model.uploadProgressLabel == "Uploading… 99%")

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
        #expect(model.uploadProgress == nil)
        #expect(model.uploadProgressLabel == nil)
    }

    @Test func allBytesSentShowsFinishingNotOneHundredPercent() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()

        await repository.report(1.0)

        #expect(model.isFinishingUpload)
        #expect(model.uploadProgressLabel == "Finishing…")
        #expect(model.uploadProgressLabel?.contains("100") == false)

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
    }

    @Test func aReportThatRestartsAtZeroLowersTheBar() async throws {
        // A 401 after the whole body went out makes the app refresh the token and send the upload again from 0.
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()

        await repository.report(1.0)
        #expect(model.isFinishingUpload)
        await repository.report(0.1)

        #expect(model.uploadProgress == 0.1)
        #expect(!model.isFinishingUpload)

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
    }

    @Test func aReportIsClampedToTheRange() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()

        await repository.report(1.7)
        #expect(model.uploadProgress == 1.0)
        await repository.report(-0.3)
        #expect(model.uploadProgress == 0)

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
    }

    @Test func aLateReportAfterTheUploadEndedChangesNothing() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let upload = Task { await model.upload() }
        await repository.waitUntilUploading()
        let handler = try #require(repository.handlers.first)

        repository.end(with: .success(Self.uploadedClip))
        await upload.value
        handler(0.97)
        await repository.settle()

        #expect(model.uploadProgress == nil)
        #expect(model.uploadProgressLabel == nil)
    }

    @Test func aReportFromAnEarlierUploadCannotMoveTheNextBar() async throws {
        let repository = HeldUploadRepository()
        let model = try makeUploadReadyViewModel(repository)
        let first = Task { await model.upload() }
        await repository.waitUntilUploading()
        let oldHandler = try #require(repository.handlers.first)
        repository.end(with: .failure(StubError.uploadFailed))
        await first.value
        #expect(model.uploadFileURL != nil)

        let second = Task { await model.upload() }
        await repository.waitUntilUploading(2)
        oldHandler(0.9)
        await repository.settle()

        #expect(model.isUploading)
        #expect(model.uploadProgress == 0)

        repository.end(with: .success(Self.uploadedClip))
        await second.value
    }

    /// A repository that holds every upload until the test ends it, and keeps the progress handler each upload was
    /// given (oldest first), so a test can report through an old handler after a new upload has started.
    private final class HeldUploadRepository: VideoUploadRepository, @unchecked Sendable {
        private(set) var handlers: [UploadProgressHandler] = []
        private var held: CheckedContinuation<FeedVideo, Error>?
        private var waiter: CheckedContinuation<Void, Never>?

        func upload(
            fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String
        ) async throws -> FeedVideo {
            try await upload(
                fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption,
                audioAssessment: nil, progress: nil)
        }

        func upload(
            fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
            audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?
        ) async throws -> FeedVideo {
            try await withCheckedThrowingContinuation { continuation in
                held = continuation
                handlers.append(progress ?? { _ in })
                waiter?.resume()
                waiter = nil
            }
        }

        /// Returns once `uploads` uploads have started.
        func waitUntilUploading(_ uploads: Int = 1) async {
            while handlers.count < uploads {
                await withCheckedContinuation { waiter = $0 }
            }
        }

        /// Reports through the newest upload's handler, then lets the main actor apply what that queued.
        func report(_ fraction: Double) async {
            handlers.last?(fraction)
            await settle()
        }

        /// The handler hops to the main actor, so give the hop time to land before a test reads the model.
        func settle() async {
            for _ in 0..<5 { await Task.yield() }
        }

        /// Ends the upload that is being held.
        func end(with result: Result<FeedVideo, Error>) {
            held?.resume(with: result)
            held = nil
        }
    }
}
