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
    let videoCount: Int
    let videos: [FeedVideo]

    init(
        handle: String,
        country: String? = nil,
        videoCount: Int = 0,
        videos: [FeedVideo] = []
    ) {
        self.handle = handle
        self.country = country
        self.videoCount = videoCount
        self.videos = videos
    }
}
