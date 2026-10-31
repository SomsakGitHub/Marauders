//
//  PostCommentUseCase.swift
//  Marauders
//

import Foundation

struct PostCommentUseCase {
    private let repository: CommentRepository

    init(repository: CommentRepository) {
        self.repository = repository
    }

    /// Posts `body` after trimming it. Throws `CommentError.invalidBody` without a request when it is empty or too long.
    func execute(videoID: UUID, body: String, language: String? = nil) async throws -> Comment {
        guard let text = CommentRules.normalized(body) else { throw CommentError.invalidBody }
        return try await repository.postComment(videoID: videoID, body: text, language: language)
    }
}
