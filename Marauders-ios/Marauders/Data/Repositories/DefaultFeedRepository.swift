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

    func fetchFeed(limit: Int) async throws -> [FeedVideo] {
        try await apiClient.fetchFeed(limit: limit)
    }
}
