//
//  FeedRepository.swift
//  Marauders
//

import Foundation

protocol FeedRepository: Sendable {
    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage
}
