//
//  DefaultCommentRepository.swift
//  Marauders
//

import Foundation

struct DefaultCommentRepository: CommentRepository {
    private let apiClient: CommentsAPIClient

    init(apiClient: CommentsAPIClient) {
        self.apiClient = apiClient
    }

    func fetchComments(videoID: UUID, cursor: UUID?, limit: Int) async throws -> CommentPage {
        try await apiClient.fetchComments(videoID: videoID, cursor: cursor, limit: limit)
    }

    func postComment(videoID: UUID, body: String, language: String?) async throws -> Comment {
        try await apiClient.postComment(videoID: videoID, body: body, language: language)
    }

    func deleteComment(videoID: UUID, commentID: UUID) async throws {
        try await apiClient.deleteComment(videoID: videoID, commentID: commentID)
    }
}
