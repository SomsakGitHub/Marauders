//
//  UploadFeedVideoUseCaseTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct UploadFeedVideoUseCaseTests {
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    @Test func executeForwardsFileLocationAndDefaultMimeType() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let repository = RecordingVideoUploadRepository(result: .success(video))
        let useCase = UploadFeedVideoUseCase(repository: repository)

        let result = try await useCase.execute(fileURL: file, clipLocation: Self.bangkok)

        #expect(result == video)
        #expect(repository.uploadCount == 1)
        #expect(repository.uploadedFileURL == file)
        #expect(repository.uploadedMimeType == "video/mp4")
        #expect(repository.uploadedClipLocation == Self.bangkok)
        #expect(repository.uploadedCaption == "")
    }

    @Test func executeForwardsCaption() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let repository = RecordingVideoUploadRepository(
            result: .success(FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!))
        )
        let useCase = UploadFeedVideoUseCase(repository: repository)

        _ = try await useCase.execute(
            fileURL: file,
            clipLocation: Self.bangkok,
            caption: "Sunset over Bangkok"
        )

        #expect(repository.uploadedCaption == "Sunset over Bangkok")
    }

    @Test func executeForwardsCustomMimeType() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let repository = RecordingVideoUploadRepository(
            result: .success(FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!))
        )
        let useCase = UploadFeedVideoUseCase(repository: repository)

        _ = try await useCase.execute(
            fileURL: file,
            clipLocation: Self.bangkok,
            mimeType: "video/quicktime"
        )

        #expect(repository.uploadedMimeType == "video/quicktime")
    }

    @Test func executePropagatesRepositoryError() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let repository = RecordingVideoUploadRepository(result: .failure(StubError.uploadFailed))
        let useCase = UploadFeedVideoUseCase(repository: repository)

        await #expect(throws: StubError.uploadFailed) {
            _ = try await useCase.execute(fileURL: file, clipLocation: Self.bangkok)
        }
    }

    @Test func executeForwardsTheProgressHandlerToTheRepository() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let useCase = UploadFeedVideoUseCase(repository: ProgressReportingRepository(video: video, fraction: 0.5))
        let log = UploadProgressLog()

        let result = try await useCase.execute(fileURL: file, clipLocation: Self.bangkok, progress: log.handler)

        #expect(result == video)
        #expect(log.values == [0.5])
    }

    @Test func aRepositoryThatKnowsNothingOfProgressStillUploads() async throws {
        let file = try TestFixtureFiles.temporaryVideoFile(byteCount: 4)
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let repository = RecordingVideoUploadRepository(result: .success(video))
        let useCase = UploadFeedVideoUseCase(repository: repository)
        let log = UploadProgressLog()

        let result = try await useCase.execute(fileURL: file, clipLocation: Self.bangkok, progress: log.handler)

        #expect(result == video)
        #expect(repository.uploadCount == 1)
        #expect(log.values.isEmpty)
    }
}

/// A repository that implements the progress overload and reports one fraction through it.
private final class ProgressReportingRepository: VideoUploadRepository, @unchecked Sendable {
    private let video: FeedVideo
    private let fraction: Double

    init(video: FeedVideo, fraction: Double) {
        self.video = video
        self.fraction = fraction
    }

    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String
    ) async throws -> FeedVideo {
        video
    }

    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?
    ) async throws -> FeedVideo {
        progress?(fraction)
        return video
    }
}
