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
    private struct LanguageInspector: ClipLanguageInspecting {
        let result: SpokenLanguageAssessment
        func inspect(fileURL: URL) async -> SpokenLanguageAssessment { result }
    }
    @Test func speechLanguageIsAttachedWithoutBlockingUploadWhenUnknown() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)),
            audioInspector: Inspector(result: .init(content: .speech, signal: .detected)),
            languageInspector: LanguageInspector(result: .unknown("permission_denied")))
        await model.prepare(sourceURL: source)
        #expect(model.audioAssessment?.spokenLanguage?.reason == "permission_denied")
        model.clipLocation = ClipLocation(latitude: 13, longitude: 100)
        #expect(model.canUpload)
        model.resetPickedFile()
    }
    @Test func musicDoesNotRunSpeechLanguageInspection() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)),
            audioInspector: Inspector(result: .init(content: .music, signal: .detected)),
            languageInspector: LanguageInspector(result: .init(status: "likely", code: "en", confidence: 0.9)))
        await model.prepare(sourceURL: source)
        #expect(model.audioAssessment?.spokenLanguage == nil)
        model.resetPickedFile()
    }
    @Test func quietAudioWarningDoesNotBlockUploadAndResetClearsIt() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let model = makeViewModel(exporter: RecordingVideoExporter(result: .success(mp4)), audioInspector: Inspector(result: .init(signal: .quietSamples)))
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
        actor DeferredInspector: ClipAudioInspecting {
            var continuation: CheckedContinuation<ClipAudioAssessment, Never>?
            var waiter: CheckedContinuation<Void, Never>?
            func inspect(fileURL: URL) async -> ClipAudioAssessment {
                await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
            }
            func waitUntilInspecting() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
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
        await inspector.finish()
        await task.value
        #expect(model.uploadFileURL == nil)
        #expect(model.audioAssessment == nil)
        #expect(!model.isPreparing)
        #expect(!FileManager.default.fileExists(atPath: mp4.path))
    }

    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    private func makeViewModel(
        exporter: VideoExporting = StubVideoExporter(result: .failure(StubError.exportFailed)),
        uploadRepository: VideoUploadRepository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed)),
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector(),
        languageInspector: any ClipLanguageInspecting = NoopClipLanguageInspector()
    ) -> UploadVideoViewModel {
        UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: exporter),
            uploadVideo: UploadFeedVideoUseCase(repository: uploadRepository),
            locationManager: locationManager,
            videoLocationReader: videoLocationReader,
            audioInspector: audioInspector,
            languageInspector: languageInspector
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
        viewModel.onUploaded = { callback.wasCalled = true }

        await viewModel.upload()

        #expect(viewModel.isSuccess)
        #expect(viewModel.statusMessage == "Upload complete — opening feed")
        #expect(viewModel.uploadFileURL == nil)
        #expect(repository.uploadedFileURL == file)
        #expect(repository.uploadedMimeType == "video/mp4")
        #expect(repository.uploadedClipLocation == Self.bangkok)
        #expect(callback.wasCalled)
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
}
