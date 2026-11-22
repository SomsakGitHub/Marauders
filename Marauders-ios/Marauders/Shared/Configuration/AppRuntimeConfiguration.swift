//
//  AppRuntimeConfiguration.swift
//  Marauders
//

import Foundation

enum AppRuntimeConfiguration {
    /// Pass `UITEST` in `XCUIApplication.launchArguments` for deterministic UI tests (mock feed, short splash).
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST")
    }

    static var uiTestUsesEmptyFeed: Bool {
        UITestFeedMode.current == .mockEmpty
    }

    /// What the force-update gate hears under `UITEST`: nothing unless a launch argument next to `UITEST` asks for an
    /// answer (the gate is otherwise off and never uses the network; docs/adr/012-force-update.md).
    static var uiTestUpdateScenario: UITestUpdateScenario {
        UITestUpdateScenario(arguments: ProcessInfo.processInfo.arguments)
    }
}
