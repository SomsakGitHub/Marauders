//
//  UITestUserProfileRepository.swift
//  Marauders
//

import Foundation

/// Fixed profile for UI tests — no network.
struct UITestUserProfileRepository: UserProfileRepository {
    func fetchProfile() async throws -> UserProfile {
        UserProfile(
            country: "TH",
            latitude: 13.7563,
            longitude: 100.5018,
            videoCount: 1,
            videos: [
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
        )
    }
}
