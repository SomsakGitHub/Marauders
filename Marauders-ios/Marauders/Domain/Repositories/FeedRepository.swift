//
//  FeedRepository.swift
//  Marauders
//

import Foundation

protocol FeedRepository: Sendable {
    func fetchFeed(limit: Int) async throws -> [FeedVideo]
}
