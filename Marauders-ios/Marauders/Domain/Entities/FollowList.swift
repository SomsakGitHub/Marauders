//
//  FollowList.swift
//  Marauders
//

import Foundation

/// Which side of a profile's follows a list shows. The raw value is the Worker's path component.
enum FollowListKind: String, CaseIterable, Hashable, Sendable {
    /// The accounts that follow the profile.
    case followers
    /// The accounts the profile follows.
    case following
}

struct FollowListEntry: Equatable, Identifiable, Sendable {
    let handle: String
    /// Nil when the account has no picture, or the Worker sent something that is not a web address.
    let avatarURL: URL?
    /// Whether the signed-in viewer follows this account. Always false on the viewer's own row.
    let followedByViewer: Bool
    /// True on the viewer's own row, which has no Follow button.
    let isViewer: Bool

    /// The same key `UserFollowsViewModel` uses, so a row and every other place that shows the account agree.
    var id: String { UserHandle.normalized(handle) }
}

/// One page of a list, newest follow first.
struct FollowListPage: Equatable, Sendable {
    let entries: [FollowListEntry]
    /// Opaque: only the Worker reads it. Nil on the last page.
    let nextCursor: String?
}

nonisolated enum FollowListRules {
    static let pageSize = 30
    /// A row this close to the end of the loaded rows asks for the next page.
    static let prefetchDistance = 5
}

enum FollowListError: LocalizedError, Equatable {
    case signInRequired
    case notFound
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in required"
        case .notFound:
            return "Profile not found"
        case .rateLimited:
            return "Too many requests, try again shortly"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}
