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

    /// What `UITEST_LONG_CAPTION` gives every clip: well past three lines at any text size, under the 500 characters
    /// the Worker allows (it has 464), and ending in words a test can look for.
    static let longCaption =
        String(repeating: "Walking the old town at sunrise, with the market stalls opening one by one. ", count: 6)
        + "The end."

    /// The clip's own caption, or none with `UITEST_NO_CAPTION`, or the long one with `UITEST_LONG_CAPTION`
    /// (`UITEST_NO_CAPTION` wins when both are given).
    private func fixtureCaption(_ own: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_NO_CAPTION") { return nil }
        if arguments.contains("UITEST_LONG_CAPTION") { return Self.longCaption }
        return own
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
            return FeedPage(
                items: FeedSampleData.videos.enumerated().map { index, sample in
                    FeedVideo(
                        streamURL: sample.streamURL, authorName: "@stream\(index)",
                        caption: fixtureCaption("Streaming test clip \(index)"))
                }, hasMore: false)
        }

        let items = [
            FeedVideo(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                streamURL: URL(string: "https://example.com/ui-test-clip.mp4")!,
                latitude: 13.7563,
                longitude: 100.5018,
                country: "TH",
                // Someone the viewer (`@marauders` in UITestUserProfileRepository) does not follow yet.
                authorName: "@traveler",
                caption: fixtureCaption("UI test clip"),
                // The two comments every clip starts with in UITestCommentRepository.
                commentCount: 2,
                postedByViewer: false,
                authorFollowedByViewer: false
            )
        ]
        return FeedPage(items: items, hasMore: false)
    }
}
