//
//  PublicUserProfile.swift
//  Marauders
//

import Foundation

/// Another user's public profile, viewable without signing in.
struct PublicUserProfile: Equatable, Sendable {
    /// Public handle (always begins with `@`).
    let handle: String
    let country: String?
    /// Public avatar image URL, when set.
    let avatarURL: URL?
    let videoCount: Int
    let videos: [FeedVideo]

    init(
        handle: String,
        country: String? = nil,
        avatarURL: URL? = nil,
        videoCount: Int = 0,
        videos: [FeedVideo] = []
    ) {
        self.handle = handle
        self.country = country
        self.avatarURL = avatarURL
        self.videoCount = videoCount
        self.videos = videos
    }
}
