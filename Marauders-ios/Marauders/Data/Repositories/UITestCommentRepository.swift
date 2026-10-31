//
//  UITestCommentRepository.swift
//  Marauders
//

import Foundation

/// In-memory comments for UI tests — no network. Every clip starts with the same two comments,
/// and posting or deleting changes what the list returns.
final class UITestCommentRepository: CommentRepository, @unchecked Sendable {
    private var storage: [UUID: [Comment]] = [:]

    func fetchComments(videoID: UUID, cursor: UUID?, limit: Int) async throws -> CommentPage {
        CommentPage(items: comments(for: videoID), nextCursor: nil)
    }

    func postComment(videoID: UUID, body: String, language: String?) async throws -> Comment {
        let comment = Comment(body: body, language: language, authorName: "@marauders", canDelete: true)
        storage[videoID] = [comment] + comments(for: videoID)
        return comment
    }

    func deleteComment(videoID: UUID, commentID: UUID) async throws {
        storage[videoID]?.removeAll { $0.id == commentID }
    }

    private func comments(for videoID: UUID) -> [Comment] {
        if let existing = storage[videoID] {
            return existing
        }
        let seeded = [
            Comment(
                body: "UI test comment from me",
                createdAt: Date().addingTimeInterval(-300),
                authorName: "@marauders",
                canDelete: true
            ),
            Comment(
                body: "UI test comment from a friend",
                createdAt: Date().addingTimeInterval(-3_600),
                authorName: "@friend"
            ),
        ]
        storage[videoID] = seeded
        return seeded
    }
}
