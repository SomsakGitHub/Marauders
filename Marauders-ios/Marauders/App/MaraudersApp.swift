//
//  MaraudersApp.swift
//  Marauders
//

import MaraudersAuthData
import SwiftUI

@main
struct MaraudersApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = AppLog.launchUptime
        // First: the session module logs through this, and the install check below may log.
        AuthLog.forwardToAppLog()
        InstallationSessionGuard.bootstrap(isUITesting: AppRuntimeConfiguration.isUITesting)
        #if DEBUG
            // After the reset above, which is what makes the stored token readable, and before anything uses it.
            DebugSessionFault.applyIfRequested()
        #endif
        // Before the UI, which a launch in the background for a location never shows.
        if !AppRuntimeConfiguration.isUITesting {
            AppDependencyContainer.backgroundLocationMonitor.resume()
            // Creates the background upload session now, before any view: the system finds the session it relaunched
            // the app for by its identifier, and hands it the events it held at once. `launch()` then starts applying
            // them and checks the upload left on disk.
            let uploader = AppDependencyContainer.clipUploader
            AppLog.info("upload.bg", "launch")
            Task { await uploader.launch() }
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
        // The system relaunches the app, in the background, when the upload session has events for it, and runs this.
        // It returns once the app has applied every event the system held (25 s at most), which is the moment the
        // system may suspend the app again.
        .backgroundTask(.urlSession(SystemBackgroundUploadSession.identifier)) { _ in
            await AppDependencyContainer.clipUploader.awaitSystemEvents()
        }
    }
}
