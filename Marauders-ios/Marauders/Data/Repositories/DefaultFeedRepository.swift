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

    func fetchMapClips(limit: Int, country: String?) async throws -> FeedPage {
        try await apiClient.fetchFeed(limit: limit, country: country, forMap: true)
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        try await apiClient.fetchFeed(limit: limit, cursor: cursor)
    }

    func fetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage {
        try await apiClient.fetchFeed(limit: limit, cursor: cursor, country: country)
    }
}
