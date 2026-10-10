//
//  FeedVideo.swift
//  Marauders
//

import Foundation

struct FeedVideo: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let streamURL: URL
    let latitude: Double?
    let longitude: Double?

    init(
        id: UUID = UUID(),
        streamURL: URL,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.latitude = latitude
        self.longitude = longitude
    }
}
