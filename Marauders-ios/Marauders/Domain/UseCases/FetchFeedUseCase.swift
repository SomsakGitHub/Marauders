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

    func executeMap(limit: Int? = nil, country: String? = nil) async throws -> FeedPage {
        try await repository.fetchMapClips(limit: limit ?? defaultLimit, country: country)
    }

    func execute(limit: Int? = nil, cursor: UUID? = nil, country: String? = nil) async throws -> FeedPage {
        try await repository.fetchFeed(
            limit: limit ?? defaultLimit,
            cursor: cursor,
            country: country
        )
    }
}
