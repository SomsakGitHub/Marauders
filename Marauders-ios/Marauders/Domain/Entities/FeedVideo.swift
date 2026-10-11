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
    /// ISO 3166-1 alpha-2 country of the uploader, when known.
    let country: String?

    init(
        id: UUID = UUID(),
        streamURL: URL,
        latitude: Double? = nil,
        longitude: Double? = nil,
        country: String? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
    }
}
