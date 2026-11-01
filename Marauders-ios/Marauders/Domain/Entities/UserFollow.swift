//
//  UserFollow.swift
//  Marauders
//

import Foundation

/// The Worker's answer to a follow or an unfollow: the viewer's state, and the counts after the change.
struct UserFollowChange: Equatable, Sendable {
    var following: Bool
    /// How many accounts follow the one the viewer followed or stopped following.
    var followerCount: Int
    /// How many accounts the viewer follows.
    var viewerFollowingCount: Int
}

enum UserFollowError: LocalizedError, Equatable {
    case signInRequired
    case notFound
    case cannotFollowSelf
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in required"
        case .notFound:
            return "Profile not found"
        case .cannotFollowSelf:
            return "You can't follow yourself"
        case .rateLimited:
            return "Too many follows, try again shortly"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}

nonisolated enum UserHandle {
    /// The form the Worker stores a handle in (`@` and lowercase), so the same account is one key wherever its handle
    /// came from.
    static func normalized(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("@") ? trimmed : "@" + trimmed
    }
}
