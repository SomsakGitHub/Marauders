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
        repo.nextResult = .success(
            FeedPage(
                items: [FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)],
                hasMore: false
            )
        )
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
        repo.nextResult = .success(
            FeedPage(
                items: [
                    FeedVideo(
                        id: videoID,
                        streamURL: URL(string: "https://example.com/a.mp4")!,
                        latitude: 13.7,
                        longitude: 100.5
                    ),
                ],
                hasMore: false
            )
        )
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

    @Test func openClipInFeedPaginatesUntilClipIsLoaded() async {
        let router = AppRouter()
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let targetID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let repo = PagingFeedRepositoryForCoordinator(firstID: firstID, targetID: targetID)
        let feedVM = VideoFeedViewModel(
            fetchFeed: FetchFeedUseCase(repository: repo, defaultLimit: 1)
        )
        await feedVM.reload()

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

        await coordinator.openClipInFeed(videoID: targetID)

        #expect(router.selectedTab == .feed)
        #expect(feedVM.focusVideoID == targetID)
        #expect(feedVM.videos.contains(where: { $0.id == targetID }))
    }
}

private final class PagingFeedRepositoryForCoordinator: FeedRepository, @unchecked Sendable {
    let firstID: UUID
    let targetID: UUID

    init(firstID: UUID, targetID: UUID) {
        self.firstID = firstID
        self.targetID = targetID
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        if cursor == nil {
            return FeedPage(
                items: [
                    FeedVideo(id: firstID, streamURL: URL(string: "https://example.com/1.mp4")!),
                ],
                hasMore: true
            )
        }
        return FeedPage(
            items: [
                FeedVideo(
                    id: targetID,
                    streamURL: URL(string: "https://example.com/target.mp4")!,
                    latitude: 13.7,
                    longitude: 100.5
                ),
            ],
            hasMore: false
        )
    }
}

private final class MockFeedRepositoryForCoordinator: FeedRepository, @unchecked Sendable {
    var nextResult: Result<FeedPage, Error> = .success(FeedPage(items: [], hasMore: false))

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
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
