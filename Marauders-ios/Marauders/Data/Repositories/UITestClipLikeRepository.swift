//
//  UITestClipLikeRepository.swift
//  Marauders
//

import Foundation

/// In-memory likes for UI tests — no network. Every clip starts with no likes.
final class UITestClipLikeRepository: ClipLikeRepository, @unchecked Sendable {
    private var liked: Set<UUID> = []

    func setLiked(_ liked: Bool, videoID: UUID) async throws -> ClipLikeState {
        if liked { self.liked.insert(videoID) } else { self.liked.remove(videoID) }
        return ClipLikeState(liked: liked, count: liked ? 1 : 0)
    }
}
