//
//  UITestUserProfileRepository.swift
//  Marauders
//

import Foundation

/// In-memory profile for UI tests — no network. Deletion mutates the store so
/// the grid can be asserted after a delete.
final class UITestUserProfileRepository: UserProfileRepository, @unchecked Sendable {
    private var videos: [FeedVideo] = [
        FeedVideo(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            streamURL: URL(string: "https://example.com/ui-test-clip.mp4")!,
            latitude: 13.7563,
            longitude: 100.5018,
            country: "TH",
            authorName: "@marauders",
            caption: "UI test clip"
        ),
    ]

    func fetchProfile() async throws -> UserProfile {
        UserProfile(
            country: "TH",
            latitude: 13.7563,
            longitude: 100.5018,
            videoCount: videos.count,
            videos: videos
        )
    }

    func deleteClip(id: UUID) async throws {
        videos.removeAll { $0.id == id }
    }
}
