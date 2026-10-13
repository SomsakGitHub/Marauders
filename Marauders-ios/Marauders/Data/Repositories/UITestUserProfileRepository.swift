//
//  UITestUserProfileRepository.swift
//  Marauders
//

import Foundation

/// In-memory profile for UI tests — no network. Deletion mutates the store so
/// the grid can be asserted after a delete.
final class UITestUserProfileRepository: UserProfileRepository, @unchecked Sendable {
    private var handle = "@marauders"
    private var avatarURL: URL?

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
            handle: handle,
            country: "TH",
            avatarURL: avatarURL,
            latitude: 13.7563,
            longitude: 100.5018,
            videoCount: videos.count,
            videos: videos
        )
    }

    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        PublicUserProfile(
            handle: handle,
            country: "TH",
            avatarURL: avatarURL,
            videoCount: videos.count,
            videos: videos
        )
    }

    func updateHandle(_ handle: String) async throws -> String {
        self.handle = handle
        return handle
    }

    func updateAvatar(imageData: Data, mimeType: String) async throws -> URL {
        let url = URL(string: "https://example.com/ui-test-avatar.\(mimeType == "image/png" ? "png" : "jpg")")!
        avatarURL = url
        return url
    }

    func deleteClip(id: UUID) async throws {
        videos.removeAll { $0.id == id }
    }
}
