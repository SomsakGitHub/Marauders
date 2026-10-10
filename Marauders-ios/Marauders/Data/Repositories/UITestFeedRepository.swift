//
//  UITestFeedRepository.swift
//  Marauders
//

import Foundation

/// Fixed feed for UI tests — no network.
struct UITestFeedRepository: FeedRepository {
    private let mode: UITestFeedMode

    init(mode: UITestFeedMode = .current) {
        self.mode = mode
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        if mode == .mockEmpty {
            return FeedPage(items: [], hasMore: false)
        }

        if cursor != nil {
            return FeedPage(items: [], hasMore: false)
        }

        let items = [
            FeedVideo(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                streamURL: URL(string: "https://example.com/ui-test-clip.mp4")!,
                latitude: 13.7563,
                longitude: 100.5018
            ),
        ]
        return FeedPage(items: items, hasMore: false)
    }
}
