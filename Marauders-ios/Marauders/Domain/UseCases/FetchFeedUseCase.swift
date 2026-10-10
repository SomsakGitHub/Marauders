//
//  FetchFeedUseCase.swift
//  Marauders
//

import Foundation

struct FetchFeedUseCase: Sendable {
    private let repository: FeedRepository
    private let defaultLimit: Int

    init(repository: FeedRepository, defaultLimit: Int = 20) {
        self.repository = repository
        self.defaultLimit = defaultLimit
    }

    func execute(limit: Int? = nil, cursor: UUID? = nil) async throws -> FeedPage {
        try await repository.fetchFeed(limit: limit ?? defaultLimit, cursor: cursor)
    }
}
