//
//  UITestLocationSharingRepository.swift
//  Marauders
//

import Foundation

/// In-memory location sharing for UI tests — no network. Sharing starts off. `@traveler`, the author of the UI-test
/// feed clip, follows the viewer back and shares, so they show on the map once the viewer follows them and shares too.
final class UITestLocationSharingRepository: LocationSharingRepository, @unchecked Sendable {
    static let friendHandle = "@traveler"

    private var sharing = false
    private let follows: UITestUserFollowRepository?

    init(follows: UITestUserFollowRepository? = nil) {
        self.follows = follows
    }

    func friendLocations() async throws -> FriendLocations {
        guard sharing else { return FriendLocations(sharing: false, friends: []) }
        guard follows?.isFollowing(Self.friendHandle) == true else {
            return FriendLocations(sharing: true, friends: [])
        }
        // About 2 km north-east of the UI-test viewer and their clip: on screen, clear of the clip's pin.
        let friend = FriendLocation(
            handle: Self.friendHandle,
            avatarURL: nil,
            latitude: 13.7700,
            longitude: 100.5150,
            updatedAt: Date().addingTimeInterval(-5 * 60)
        )
        return FriendLocations(sharing: true, friends: [friend])
    }

    func setSharing(_ enabled: Bool) async throws -> Bool {
        sharing = enabled
        return enabled
    }
}
