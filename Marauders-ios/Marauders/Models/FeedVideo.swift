//
//  FeedVideo.swift
//  Marauders
//

import Foundation

struct FeedVideo: Identifiable, Hashable, Sendable {
    let id: UUID
    let streamURL: URL
    let authorName: String
    let caption: String
    let musicTitle: String

    init(
        id: UUID = UUID(),
        streamURL: URL,
        authorName: String,
        caption: String,
        musicTitle: String
    ) {
        self.id = id
        self.streamURL = streamURL
        self.authorName = authorName
        self.caption = caption
        self.musicTitle = musicTitle
    }
}
