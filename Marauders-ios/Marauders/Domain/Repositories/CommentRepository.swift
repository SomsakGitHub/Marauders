//
//  CommentRepository.swift
//  Marauders
//

import Foundation

protocol CommentRepository: Sendable {
    /// Newest first. `cursor` is the id of the last comment of the previous page, which is what the Worker hands back as
    /// `nextCursor`; a cursor that no longer exists (that comment was deleted) answers an empty page.
    func fetchComments(videoID: UUID, cursor: UUID?, limit: Int) async throws -> CommentPage
    func postComment(videoID: UUID, body: String, language: String?) async throws -> Comment
    func deleteComment(videoID: UUID, commentID: UUID) async throws
}
