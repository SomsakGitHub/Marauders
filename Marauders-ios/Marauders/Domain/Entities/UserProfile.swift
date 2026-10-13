//
//  UserProfile.swift
//  Marauders
//

import Foundation

/// The signed-in user's account summary plus the clips they have uploaded.
struct UserProfile: Equatable, Sendable {
    /// Public handle (always begins with `@`).
    let handle: String
    let country: String?
    /// Public avatar image URL, when set.
    let avatarURL: URL?
    let latitude: Double?
    let longitude: Double?
    let videoCount: Int
    let videos: [FeedVideo]

    init(
        handle: String = "@marauders",
        country: String? = nil,
        avatarURL: URL? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        videoCount: Int = 0,
        videos: [FeedVideo] = []
    ) {
        self.handle = handle
        self.country = country
        self.avatarURL = avatarURL
        self.latitude = latitude
        self.longitude = longitude
        self.videoCount = videoCount
        self.videos = videos
    }
}
