//
//  FeedVideo.swift
//  Marauders
//

import Foundation

struct FeedVideo: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let streamURL: URL

    init(id: UUID = UUID(), streamURL: URL) {
        self.id = id
        self.streamURL = streamURL
    }
}
