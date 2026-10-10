//
//  AppCoordinatorTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@MainActor
struct AppCoordinatorTests {
    @Test func uploadCompletedReloadsFeedAndShowsFeedTab() async {
        let router = AppRouter()
        router.showUpload()

        let repo = MockFeedRepositoryForCoordinator()
        repo.nextResult = .success([
            FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!),
        ])
        let feedVM = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))
        let uploadVM = UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: FailingExporter()),
            uploadVideo: UploadFeedVideoUseCase(
                repository: MockUploadRepository(result: .failure(URLError(.cancelled)))
            )
        )

        let coordinator = AppCoordinator(
            router: router,
            feedViewModel: feedVM,
            uploadViewModel: uploadVM
        )
        await coordinator.handleUploadCompleted()

        #expect(router.selectedTab == .feed)
        #expect(feedVM.videos.count == 1)
    }

    @Test func openClipInFeedFocusesVideoAndShowsFeedTab() async {
        let router = AppRouter()
        let videoID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let repo = MockFeedRepositoryForCoordinator()
        repo.nextResult = .success([
            FeedVideo(
                id: videoID,
                streamURL: URL(string: "https://example.com/a.mp4")!,
                latitude: 13.7,
                longitude: 100.5
            ),
        ])
        let feedVM = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))
        let uploadVM = UploadVideoViewModel(
            prepareVideo: PrepareVideoForUploadUseCase(exporter: FailingExporter()),
            uploadVideo: UploadFeedVideoUseCase(
                repository: MockUploadRepository(result: .failure(URLError(.cancelled)))
            )
        )
        let coordinator = AppCoordinator(
            router: router,
            feedViewModel: feedVM,
            uploadViewModel: uploadVM
        )

        await coordinator.openClipInFeed(videoID: videoID)

        #expect(router.selectedTab == .feed)
        #expect(feedVM.focusVideoID == videoID)
    }
}

private final class MockFeedRepositoryForCoordinator: FeedRepository, @unchecked Sendable {
    var nextResult: Result<[FeedVideo], Error> = .success([])

    func fetchFeed(limit: Int) async throws -> [FeedVideo] {
        try nextResult.get()
    }
}

private struct MockUploadRepository: VideoUploadRepository {
    let result: Result<FeedVideo, Error>

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation
    ) async throws -> FeedVideo {
        try result.get()
    }
}

private struct FailingExporter: VideoExporting {
    func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        throw URLError(.cannotOpenFile)
    }
}
