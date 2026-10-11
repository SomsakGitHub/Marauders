//
//  FeedRepository.swift
//  Marauders
//

import Foundation

protocol FeedRepository: Sendable {
    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage

    /// Optional country filter (ISO 3166-1 alpha-2); `nil` returns every country.
    func fetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage
}

extension FeedRepository {
    /// Default: ignore the country filter (simple stubs / non-filtering repositories).
    func fetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage {
        try await fetchFeed(limit: limit, cursor: cursor)
    }
}
