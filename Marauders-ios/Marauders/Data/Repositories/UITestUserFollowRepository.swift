//
//  UITestUserFollowRepository.swift
//  Marauders
//

import Foundation

/// In-memory follows for UI tests — no network. Nobody follows anybody at launch, and the viewer is each account's only
/// possible follower. `UITestUserProfileRepository` reads it, so a profile opened after a follow says the same.
final class UITestUserFollowRepository: UserFollowRepository, @unchecked Sendable {
    private var followed: Set<String> = []

    func isFollowing(_ handle: String) -> Bool {
        followed.contains(UserHandle.normalized(handle))
    }

    var followedCount: Int { followed.count }

    /// The accounts the viewer follows, normalized and in a fixed order, for the viewer's Following list.
    var followedHandles: [String] { followed.sorted() }

    func setFollowing(_ following: Bool, handle: String) async throws -> UserFollowChange {
        let key = UserHandle.normalized(handle)
        if following { followed.insert(key) } else { followed.remove(key) }
        return UserFollowChange(following: following, followerCount: following ? 1 : 0, viewerFollowingCount: followed.count)
    }
}
