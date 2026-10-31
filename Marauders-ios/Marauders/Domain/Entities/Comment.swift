//
//  Comment.swift
//  Marauders
//

import Foundation

struct Comment: Identifiable, Hashable, Sendable {
    let id: UUID
    let body: String
    /// Base language code the author's iPhone reported for the text, when it did.
    let language: String?
    let createdAt: Date
    let authorName: String?
    let authorAvatarURL: URL?
    /// True when the signed-in viewer wrote the comment or owns the clip it sits on.
    let canDelete: Bool

    init(
        id: UUID = UUID(),
        body: String,
        language: String? = nil,
        createdAt: Date = Date(),
        authorName: String? = nil,
        authorAvatarURL: URL? = nil,
        canDelete: Bool = false
    ) {
        self.id = id
        self.body = body
        self.language = language
        self.createdAt = createdAt
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.canDelete = canDelete
    }
}

/// One page of a clip's comments, newest first.
struct CommentPage: Equatable, Sendable {
    let items: [Comment]
    /// The id of this page's last comment when older ones exist, nil on the last page. The app only reads whether it is
    /// set, and asks for the next page after the last comment it still lists: the one named here may be deleted by then.
    let nextCursor: UUID?
}

nonisolated enum CommentRules {
    /// The Worker refuses longer comments (`COMMENT_MAX_CHARS`).
    static let maxCharacters = 500
    static let pageSize = 30

    /// Counted in Unicode scalars because the Worker counts code points, so what fits here fits there.
    static func characterCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// The text to send: surrounding whitespace removed. Nil when nothing a reader could see is left or it is too long.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasVisibleCharacter(trimmed), characterCount(trimmed) <= maxCharacters else { return nil }
        return trimmed
    }

    /// False for text that draws nothing, which would post as a blank row: whitespace, control and zero-width
    /// characters, variation selectors, the fillers that stand in for a missing Hangul letter, the Braille blank
    /// and the object replacement character. The Worker applies the same rule (`normalizeCommentBody`).
    static func hasVisibleCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let properties = scalar.properties
            if properties.isWhitespace || properties.isDefaultIgnorableCodePoint || properties.generalCategory == .control {
                return false
            }
            return scalar.value != 0x2800 && scalar.value != 0xFFFC
        }
    }
}

enum CommentError: LocalizedError, Equatable {
    case signInRequired
    case notFound
    case invalidBody
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in required"
        case .notFound:
            return "Comment or clip not found"
        case .invalidBody:
            return "A comment must be 1 to \(CommentRules.maxCharacters) characters"
        case .rateLimited:
            return "Too many comments, try again shortly"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}
