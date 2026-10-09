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
}

private final class MockFeedRepositoryForCoordinator: FeedRepository, @unchecked Sendable {
    var nextResult: Result<[FeedVideo], Error> = .success([])

    func fetchFeed(limit: Int) async throws -> [FeedVideo] {
        try nextResult.get()
    }
}

private struct MockUploadRepository: VideoUploadRepository {
    let result: Result<FeedVideo, Error>

    func upload(fileURL: URL, mimeType: String) async throws -> FeedVideo {
        try result.get()
    }
}

private struct FailingExporter: VideoExporting {
    func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        throw URLError(.cannotOpenFile)
    }
}
