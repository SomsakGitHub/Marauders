//
//  DefaultFeedRepository.swift
//  Marauders
//

import Foundation

struct DefaultFeedRepository: FeedRepository {
    private let apiClient: FeedAPIClient

    init(apiClient: FeedAPIClient) {
        self.apiClient = apiClient
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        try await apiClient.fetchFeed(limit: limit, cursor: cursor)
    }
}
