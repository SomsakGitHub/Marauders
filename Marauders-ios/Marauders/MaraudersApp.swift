//
//  MaraudersApp.swift
//  Marauders
//

import SwiftUI

@main
struct MaraudersApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    VideoPlaybackConfigurator.activateAudioSessionIfNeeded()
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
    }
}
