//
//  FriendLocation.swift
//  Marauders
//

import CoreLocation
import Foundation

/// Where a mutual follower who shares their location last was: someone the viewer follows who follows them back.
struct FriendLocation: Identifiable, Equatable, Sendable {
    var id: String { handle }
    let handle: String
    let avatarURL: URL?
    let latitude: Double
    let longitude: Double
    /// When their iPhone last sent it; nil when the Worker has no time for it.
    let updatedAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What the Worker says about location sharing for the viewer.
struct FriendLocations: Equatable, Sendable {
    /// Whether the viewer shares their own location; others' come back only while they do.
    let sharing: Bool
    /// Whether the viewer's own location is on file; others' come back only once it is.
    let located: Bool
    let friends: [FriendLocation]

    nonisolated init(sharing: Bool, located: Bool = true, friends: [FriendLocation]) {
        self.sharing = sharing
        self.located = located
        self.friends = friends
    }
}

enum LocationSharingError: LocalizedError, Equatable {
    case signInRequired
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in required"
        case .rateLimited:
            return "Too many changes, try again shortly"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}
