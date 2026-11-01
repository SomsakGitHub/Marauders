//
//  SetClipLikeUseCase.swift
//  Marauders
//

import Foundation

struct SetClipLikeUseCase {
    private let repository: ClipLikeRepository

    init(repository: ClipLikeRepository) {
        self.repository = repository
    }

    func execute(videoID: UUID, liked: Bool) async throws -> ClipLikeState {
        try await repository.setLiked(liked, videoID: videoID)
    }
}
