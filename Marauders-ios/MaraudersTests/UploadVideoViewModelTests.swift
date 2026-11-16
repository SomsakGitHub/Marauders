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
    @Test func withoutAnInspectorTheViewModelDoesNotAnalyseTheAudioItself() async throws {
        // The real inspector is a Data type, so the composition root hands it in. A view model made without one has
        // none: the real inspector reports this tone as detected.
        let clip = try TestFixtureFiles.temporaryToneFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        let model = UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: StubVideoExporter(result: .success(clip))))
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

    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    private func makeViewModel(
        exporter: VideoExporting = StubVideoExporter(result: .failure(StubError.exportFailed)),
        uploader: FakeClipUploader = FakeClipUploader(),
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector(),
        holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    ) -> UploadVideoViewModel {
        UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: exporter),
            uploads: ClipUploadUseCases(uploader: uploader),
            locationManager: locationManager,
            videoLocationReader: videoLocationReader,
            audioInspector: audioInspector,
            holdAwake: holdAwake
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
        let uploader = FakeClipUploader()
        let viewModel = makeViewModel(uploader: uploader)

        await viewModel.upload()

        #expect(viewModel.statusMessage == nil)
        #expect(viewModel.isUploading == false)
        #expect(uploader.started.isEmpty)
    }

    @Test func uploadWithoutClipLocationPromptsUser() async throws {
        let uploader = FakeClipUploader()
        let viewModel = makeViewModel(uploader: uploader)
        viewModel.uploadFileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)

        await viewModel.upload()

        #expect(viewModel.statusMessage == "Set the clip location before uploading")
        #expect(viewModel.isSuccess == false)
        #expect(uploader.started.isEmpty)
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
