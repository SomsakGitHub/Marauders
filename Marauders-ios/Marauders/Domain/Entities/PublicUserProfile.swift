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
    /// How many accounts follow this one; nil from a Worker that predates follows.
    let followerCount: Int?
    /// How many accounts this one follows; nil from a Worker that predates follows.
    let followingCount: Int?
    /// Whether the viewer who asked follows this account; false for a guest, nil where the Worker predates follows.
    let followedByViewer: Bool?
    /// Whether the profile is the viewer's own; nil where the Worker predates follows.
    let isViewer: Bool?

    init(
        handle: String,
        country: String? = nil,
        avatarURL: URL? = nil,
        videoCount: Int = 0,
        videos: [FeedVideo] = [],
        followerCount: Int? = nil,
        followingCount: Int? = nil,
        followedByViewer: Bool? = nil,
        isViewer: Bool? = nil
    ) {
        self.handle = handle
        self.country = country
        self.avatarURL = avatarURL
        self.videoCount = videoCount
        self.videos = videos
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.followedByViewer = followedByViewer
        self.isViewer = isViewer
    }
}
