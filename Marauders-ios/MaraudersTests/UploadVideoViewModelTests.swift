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
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    private func makeViewModel(
        exporter: VideoExporting = StubVideoExporter(result: .failure(StubError.exportFailed)),
        uploadRepository: VideoUploadRepository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))
    ) -> UploadVideoViewModel {
        UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: exporter),
            uploadVideo: UploadFeedVideoUseCase(repository: uploadRepository),
            locationManager: CLLocationManager()
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
}
