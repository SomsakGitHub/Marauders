//
//  DeleteCommentUseCase.swift
//  Marauders
//

import Foundation

struct DeleteCommentUseCase {
    private let repository: CommentRepository

    init(repository: CommentRepository) {
        self.repository = repository
    }

    func execute(videoID: UUID, commentID: UUID) async throws {
        try await repository.deleteComment(videoID: videoID, commentID: commentID)
    }
}
