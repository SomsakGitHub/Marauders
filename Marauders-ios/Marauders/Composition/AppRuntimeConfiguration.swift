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
}
