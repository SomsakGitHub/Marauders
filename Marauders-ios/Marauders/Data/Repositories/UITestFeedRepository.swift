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
        try await fetchFeed(limit: limit, cursor: cursor, country: nil)
    }

    func fetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage {
        if mode == .mockEmpty {
            return FeedPage(items: [], hasMore: false)
        }

        if cursor != nil {
            return FeedPage(items: [], hasMore: false)
        }

        if ProcessInfo.processInfo.arguments.contains("UITEST_STREAMING_FEED") {
            return FeedPage(items: FeedSampleData.videos.enumerated().map { index, sample in
                FeedVideo(streamURL: sample.streamURL, authorName: "@stream\(index)", caption: "Streaming test clip \(index)")
            }, hasMore: false)
        }

        let items = [
            FeedVideo(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                streamURL: URL(string: "https://example.com/ui-test-clip.mp4")!,
                latitude: 13.7563,
                longitude: 100.5018,
                country: "TH",
                authorName: "@marauders",
                caption: "UI test clip"
            ),
        ]
        return FeedPage(items: items, hasMore: false)
    }
}
