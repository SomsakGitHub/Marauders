//
//  FeedPage.swift
//  Marauders
//

import Foundation

struct FeedPage: Sendable, Equatable {
    let items: [FeedVideo]
    /// `true` when `items.count == limit` (another page may exist).
    let hasMore: Bool
}
