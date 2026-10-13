//
//  AppRouter.swift
//  Marauders
//

import Foundation
import Observation

/// A public profile to present modally (from a tapped author handle).
struct PublicProfileRoute: Identifiable, Equatable {
    var id: String { handle }
    let handle: String
}

/// Presentation-level navigation state (tabs). Views bind here; coordinators mutate routes.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: MainTab = .feed
    /// Non-nil while a public profile sheet is presented.
    var publicProfileRoute: PublicProfileRoute?

    func openPublicProfile(handle: String) {
        publicProfileRoute = PublicProfileRoute(handle: handle)
    }

    func showFeed() {
        selectedTab = .feed
    }

    func showMap() {
        selectedTab = .map
    }

    func showUpload() {
        selectedTab = .upload
    }

    #if DEBUG
    func showDebugLog() {
        selectedTab = .log
    }
    #endif
}
