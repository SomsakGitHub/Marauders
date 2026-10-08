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

    func execute(limit: Int? = nil) async throws -> [FeedVideo] {
        try await repository.fetchFeed(limit: limit ?? defaultLimit)
    }
}
