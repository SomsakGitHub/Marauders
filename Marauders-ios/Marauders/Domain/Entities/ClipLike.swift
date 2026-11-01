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
            return "Sign in required"
        case .notFound:
            return "Clip not found"
        case .rateLimited:
            return "Too many likes, try again shortly"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}
