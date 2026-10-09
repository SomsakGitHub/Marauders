//
//  VideoFeedViewModelTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

private struct MockFeedRepository: FeedRepository {
    var result: Result<[FeedVideo], Error>

    func fetchFeed(limit: Int) async throws -> [FeedVideo] {
        try result.get()
    }
}

@MainActor
struct VideoFeedViewModelTests {
    @Test func reloadEmptyFeedSetsFailedState() async {
        let repo = MockFeedRepository(result: .success([]))
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))

        await viewModel.reload()

        #expect(viewModel.videos.isEmpty)
        #expect(viewModel.loadState == .failed("Feed is empty — try uploading a clip"))
    }

    @Test func staleReloadResponseIsIgnored() async {
        final class DelayedRepository: FeedRepository, @unchecked Sendable {
            var firstContinuation: CheckedContinuation<[FeedVideo], Error>?

            func fetchFeed(limit: Int) async throws -> [FeedVideo] {
                if firstContinuation == nil {
                    return try await withCheckedThrowingContinuation { continuation in
                        firstContinuation = continuation
                    }
                }
                return [
                    FeedVideo(
                        streamURL: URL(string: "https://example.com/new.mp4")!
                    ),
                ]
            }

            func completeFirst(with videos: [FeedVideo]) {
                firstContinuation?.resume(returning: videos)
                firstContinuation = nil
            }
        }

        let repo = DelayedRepository()
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repo))

        async let first: Void = viewModel.reload()
        await Task.yield()
        async let second: Void = viewModel.reload()
        repo.completeFirst(with: [
            FeedVideo(streamURL: URL(string: "https://example.com/stale.mp4")!),
        ])
        await first
        await second

        #expect(viewModel.videos.first?.streamURL.absoluteString.contains("new.mp4") == true)
    }
}
