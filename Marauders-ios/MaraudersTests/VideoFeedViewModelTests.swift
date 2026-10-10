//
//  VideoFeedViewModelTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

private struct MockFeedRepository: FeedRepository {
    var result: Result<FeedPage, Error>

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        try result.get()
    }
}

@MainActor
struct VideoFeedViewModelTests {
    @Test func reloadEmptyFeedSetsFailedState() async {
        let repo = MockFeedRepository(result: .success(FeedPage(items: [], hasMore: false)))
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))

        await viewModel.reload()

        #expect(viewModel.videos.isEmpty)
        #expect(viewModel.loadState == .failed("Feed is empty — try uploading a clip"))
    }

    @Test func staleReloadResponseIsIgnored() async {
        final class DelayedRepository: FeedRepository, @unchecked Sendable {
            var firstContinuation: CheckedContinuation<FeedPage, Error>?

            func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
                if firstContinuation == nil {
                    return try await withCheckedThrowingContinuation { continuation in
                        firstContinuation = continuation
                    }
                }
                return FeedPage(
                    items: [
                        FeedVideo(
                            streamURL: URL(string: "https://example.com/new.mp4")!
                        ),
                    ],
                    hasMore: false
                )
            }

            func completeFirst(with page: FeedPage) {
                firstContinuation?.resume(returning: page)
                firstContinuation = nil
            }
        }

        let repo = DelayedRepository()
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))

        async let first: Void = viewModel.reload()
        await Task.yield()
        async let second: Void = viewModel.reload()
        repo.completeFirst(
            with: FeedPage(
                items: [FeedVideo(streamURL: URL(string: "https://example.com/stale.mp4")!)],
                hasMore: false
            )
        )
        await first
        await second

        #expect(viewModel.videos.first?.streamURL.absoluteString.contains("new.mp4") == true)
    }

    @Test func loadMoreAppendsNextPage() async {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        final class PagingRepository: FeedRepository, @unchecked Sendable {
            let firstID: UUID
            let secondID: UUID

            init(firstID: UUID, secondID: UUID) {
                self.firstID = firstID
                self.secondID = secondID
            }

            func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
                if cursor == nil {
                    return FeedPage(
                        items: [
                            FeedVideo(
                                id: firstID,
                                streamURL: URL(string: "https://example.com/1.mp4")!
                            ),
                        ],
                        hasMore: true
                    )
                }
                #expect(cursor == firstID)
                return FeedPage(
                    items: [
                        FeedVideo(
                            id: secondID,
                            streamURL: URL(string: "https://example.com/2.mp4")!
                        ),
                    ],
                    hasMore: false
                )
            }
        }

        let viewModel = VideoFeedViewModel(
            fetchFeed: FetchFeedUseCase(
                repository: PagingRepository(firstID: id1, secondID: id2),
                defaultLimit: 1
            )
        )
        await viewModel.reload()
        #expect(viewModel.videos.count == 1)

        await viewModel.loadMoreIfNearEnd(currentIndex: 0)
        #expect(viewModel.videos.count == 2)
        #expect(viewModel.videos.last?.id == id2)
    }

    @Test func syncHeadPrependsNewClipWithoutDroppingTail() async {
        let id1 = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let id2 = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let newID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

        final class HeadRepository: FeedRepository, @unchecked Sendable {
            let id1: UUID
            let id2: UUID
            let newID: UUID
            var callCount = 0

            init(id1: UUID, id2: UUID, newID: UUID) {
                self.id1 = id1
                self.id2 = id2
                self.newID = newID
            }

            func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
                callCount += 1
                switch callCount {
                case 1:
                    return FeedPage(
                        items: [
                            FeedVideo(id: self.id1, streamURL: URL(string: "https://example.com/1.mp4")!),
                        ],
                        hasMore: true
                    )
                case 2:
                    return FeedPage(
                        items: [
                            FeedVideo(id: self.id2, streamURL: URL(string: "https://example.com/2.mp4")!),
                        ],
                        hasMore: false
                    )
                default:
                    return FeedPage(
                        items: [
                            FeedVideo(
                                id: self.newID,
                                streamURL: URL(string: "https://example.com/new.mp4")!,
                                latitude: 1,
                                longitude: 2
                            ),
                            FeedVideo(id: self.id1, streamURL: URL(string: "https://example.com/1.mp4")!),
                        ],
                        hasMore: false
                    )
                }
            }
        }

        let repo = HeadRepository(id1: id1, id2: id2, newID: newID)
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo, defaultLimit: 1))

        await viewModel.reload()
        await viewModel.loadMoreIfNearEnd(currentIndex: 0)
        #expect(viewModel.videos.count == 2)

        await viewModel.syncHeadWithServer()
        #expect(viewModel.videos.first?.id == newID)
        #expect(viewModel.videos.count == 3)
        #expect(viewModel.videosWithMapCoordinates.count == 1)
    }
}
