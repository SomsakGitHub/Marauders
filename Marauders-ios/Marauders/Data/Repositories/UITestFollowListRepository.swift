//
//  UITestFollowListRepository.swift
//  Marauders
//

import Foundation

/// In-memory follower and following lists for UI tests — no network. They agree with the counts
/// `UITestUserProfileRepository` reports: nobody follows the viewer (`@marauders`), the viewer is every other account's
/// only possible follower, and the accounts the viewer follows are the ones the Follow buttons made. One page, no cursor.
final class UITestFollowListRepository: FollowListRepository, @unchecked Sendable {
    private static let viewerHandle = "@marauders"
    private let follows: UITestUserFollowRepository

    init(follows: UITestUserFollowRepository) {
        self.follows = follows
    }

    func fetchList(handle: String, kind: FollowListKind, cursor: String?, limit: Int) async throws -> FollowListPage {
        let owner = UserHandle.normalized(handle)
        let ownerIsViewer = owner == Self.viewerHandle
        let entries: [FollowListEntry]
        switch kind {
        case .followers:
            let viewerFollowsOwner = !ownerIsViewer && follows.isFollowing(owner)
            entries = viewerFollowsOwner
                ? [FollowListEntry(handle: Self.viewerHandle, avatarURL: nil, followedByViewer: false, isViewer: true)]
                : []
        case .following:
            entries = ownerIsViewer
                ? follows.followedHandles.map {
                    FollowListEntry(handle: $0, avatarURL: nil, followedByViewer: true, isViewer: false)
                }
                : []
        }
        return FollowListPage(entries: entries, nextCursor: nil)
    }
}
