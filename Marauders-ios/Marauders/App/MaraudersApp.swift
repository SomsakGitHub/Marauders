//
//  MaraudersApp.swift
//  Marauders
//

import MaraudersAuthData
import SwiftUI

@main
struct MaraudersApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Whether this build is too old to keep working (docs/adr/012-force-update.md). Built before `init()` runs, from
    /// what the last launch kept: it reads UserDefaults and starts no request, so a build without the pass is still
    /// not asked to do anything (`refreshIfDue` below follows the pass check).
    @State private var updateGate = UpdateGateComposition.makeViewModel()

    init() {
        _ = AppLog.launchUptime
        // The pass (docs/ci-cd.md): a build that does not carry it starts nothing, and `body` shows the block screen.
        guard ClientKey.appMayRun() else {
            AppLog.error("app", "client key is not the pass: nothing starts")
            return
        }
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
            if ClientKey.appMayRun() {
                if case .required(let updateURL) = updateGate.decision {
                    UpdateRequiredView(updateURL: updateURL)
                } else {
                    AppRootView()
                }
            } else {
                ClientKeyBlockedView()
            }
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
        // One ask for the gate's minimum at launch and one at each foreground, at most once per ten minutes (the view
        // model keeps the count). The first ask is what starts Firebase; a build without the pass asks nothing, so it
        // never starts it.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, ClientKey.appMayRun() else { return }
            Task { await updateGate.refreshIfDue() }
        }
        // The system relaunches the app, in the background, when the upload session has events for it, and runs this.
        // It returns once the app has applied every event the system held (25 s at most), which is the moment the
        // system may suspend the app again. A build that is not the pass has started no uploader: it returns at once.
        .backgroundTask(.urlSession(SystemBackgroundUploadSession.identifier)) { _ in
            guard ClientKey.appMayRun() else { return }
            await AppDependencyContainer.clipUploader.awaitSystemEvents()
        }
    }
}
