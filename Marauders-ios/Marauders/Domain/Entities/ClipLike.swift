//
//  ClipLike.swift
//  Marauders
//

import Foundation

/// Whether the viewer likes a clip, and how many viewers do.
struct ClipLikeState: Equatable, Sendable {
    var liked: Bool
    var count: Int
}

enum ClipLikeError: LocalizedError, Equatable {
    case signInRequired
    case notFound
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return String(localized: "Sign in required")
        case .notFound:
            return String(localized: "Clip not found")
        case .rateLimited:
            return String(localized: "Too many likes, try again shortly")
        case .invalidResponse:
            return String(localized: "Invalid server response")
        case .serverError(let code):
            return String(localized: "Server responded with status \(code)")
        }
    }
}
