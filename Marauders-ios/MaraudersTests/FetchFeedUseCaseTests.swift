//
//  FetchFeedUseCaseTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@MainActor
struct FetchFeedUseCaseTests {
    @Test func executeUsesDefaultLimitAndNoCursor() async throws {
        let repository = RecordingFeedRepository(
            result: .success(FeedPage(items: [], hasMore: true))
        )
        let useCase = FetchFeedUseCase(repository: repository, defaultLimit: 7)

        _ = try await useCase.execute()

        #expect(repository.fetchCount == 1)
        #expect(repository.lastLimit == 7)
        #expect(repository.lastCursor == nil)
    }

    @Test func executeOverridesLimitAndForwardsCursor() async throws {
        let cursor = UUID()
        let repository = RecordingFeedRepository(
            result: .success(FeedPage(items: [], hasMore: false))
        )
        let useCase = FetchFeedUseCase(repository: repository, defaultLimit: 20)

        _ = try await useCase.execute(limit: 3, cursor: cursor)

        #expect(repository.lastLimit == 3)
        #expect(repository.lastCursor == cursor)
    }

    @Test func executeReturnsRepositoryPage() async throws {
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let page = FeedPage(items: [video], hasMore: false)
        let useCase = FetchFeedUseCase(
            repository: RecordingFeedRepository(result: .success(page))
        )

        let result = try await useCase.execute()

        #expect(result == page)
    }

    @Test func executePropagatesRepositoryError() async {
        let useCase = FetchFeedUseCase(
            repository: RecordingFeedRepository(result: .failure(StubError.feedFailed))
        )

        await #expect(throws: StubError.feedFailed) {
            _ = try await useCase.execute()
        }
    }
}
