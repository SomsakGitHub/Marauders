//
//  LoadCommentsUseCase.swift
//  Marauders
//

import Foundation

struct LoadCommentsUseCase {
    private let repository: CommentRepository

    init(repository: CommentRepository) {
        self.repository = repository
    }

    func execute(videoID: UUID, cursor: UUID? = nil, limit: Int = CommentRules.pageSize) async throws -> CommentPage {
        try await repository.fetchComments(videoID: videoID, cursor: cursor, limit: limit)
    }
}
