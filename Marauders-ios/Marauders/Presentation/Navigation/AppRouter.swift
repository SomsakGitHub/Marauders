//
//  AppRouter.swift
//  Marauders
//

import Foundation
import Observation

/// Presentation-level navigation state (tabs). Views bind here; coordinators mutate routes.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: MainTab = .feed

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
