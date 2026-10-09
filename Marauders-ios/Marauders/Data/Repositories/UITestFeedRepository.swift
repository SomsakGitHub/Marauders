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

    func fetchFeed(limit: Int) async throws -> [FeedVideo] {
        if mode == .mockEmpty {
            return []
        }

        return [
            FeedVideo(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                streamURL: URL(string: "https://example.com/ui-test-clip.mp4")!
            ),
        ]
    }
}
