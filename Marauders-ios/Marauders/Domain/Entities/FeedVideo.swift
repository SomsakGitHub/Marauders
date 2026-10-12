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
    /// Display handle of the uploader, when known.
    let authorName: String?
    /// Caption text shown with the clip, when known.
    let caption: String?
    /// Music title shown with the clip, when known.
    let musicTitle: String?

    init(
        id: UUID = UUID(),
        streamURL: URL,
        latitude: Double? = nil,
        longitude: Double? = nil,
        country: String? = nil,
        authorName: String? = nil,
        caption: String? = nil,
        musicTitle: String? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
        self.authorName = authorName
        self.caption = caption
        self.musicTitle = musicTitle
    }
}
