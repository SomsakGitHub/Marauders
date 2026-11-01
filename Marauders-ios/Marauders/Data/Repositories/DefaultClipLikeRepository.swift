//
//  DefaultClipLikeRepository.swift
//  Marauders
//

import Foundation

struct DefaultClipLikeRepository: ClipLikeRepository {
    private let apiClient: LikesAPIClient

    init(apiClient: LikesAPIClient) {
        self.apiClient = apiClient
    }

    func setLiked(_ liked: Bool, videoID: UUID) async throws -> ClipLikeState {
        try await apiClient.setLiked(liked, videoID: videoID)
    }
}
