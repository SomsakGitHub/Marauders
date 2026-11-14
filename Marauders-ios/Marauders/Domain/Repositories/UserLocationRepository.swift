//
//  UserLocationRepository.swift
//  Marauders
//

import Foundation

protocol UserLocationRepository: Sendable {
    func report(location: ClipLocation) async throws
    /// What the app sends while it is closed. The Worker keeps it only while the viewer shares, and answers whether they
    /// still do; nil from a Worker that does not say.
    func reportWhileClosed(location: ClipLocation) async throws -> Bool?
}

/// What reporting a location throws. The background monitor reads it to see whether the session has ended.
enum UserLocationAPIError: LocalizedError, Equatable {
    case notAuthenticated
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in required"
        case .serverError(let code):
            return "Location report failed (status \(code))"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}
