//
//  MaraudersApp.swift
//  Marauders
//

import SwiftUI

@main
struct MaraudersApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = AppLog.launchUptime
        InstallationSessionGuard.bootstrap()
        // Before the UI, which a launch in the background for a location never shows.
        if !AppRuntimeConfiguration.isUITesting {
            AppDependencyContainer.backgroundLocationMonitor.resume()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                AppLog.info("app", "entered background")
            case .inactive:
                AppLog.debug("app", "inactive")
            case .active:
                AppLog.debug("app", "active")
            @unknown default:
                break
            }
        }
    }
}
