//
//  ClipLikeRepository.swift
//  Marauders
//

import Foundation

protocol ClipLikeRepository: Sendable {
    /// Likes the clip, or takes the like back, as the signed-in viewer. Returns the state the Worker stored, count included.
    func setLiked(_ liked: Bool, videoID: UUID) async throws -> ClipLikeState
}
