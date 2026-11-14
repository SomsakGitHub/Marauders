//
//  FeedStartupCaching.swift
//  Marauders
//

import Foundation

/// The first clips of the feed, kept on this iPhone with their video files so the next launch can show one before the
/// network answers.
protocol FeedStartupCaching: Sendable {
    func cachedVideos() async -> [FeedVideo]
    func store(_ videos: [FeedVideo]) async
}

/// The video files that cache holds. A clip with a file here plays from disk instead of streaming again.
protocol FeedMediaCaching: Sendable {
    func localURL(for remote: URL) async -> URL?
    func invalidate(_ remote: URL) async
}
