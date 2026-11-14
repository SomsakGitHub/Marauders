//
//  UITestFeedMode.swift
//  Marauders
//

import Foundation

/// Resolved once at first access from launch configuration (UI tests).
enum UITestFeedMode: Sendable {
    case production
    case mockPopulated
    case mockEmpty

    static let current: UITestFeedMode = {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment

        guard arguments.contains("UITEST") || environment["UITEST"] == "1" else {
            return .production
        }

        if arguments.contains("UITEST_EMPTY_FEED") || environment["UITEST_EMPTY_FEED"] == "1" {
            return .mockEmpty
        }

        return .mockPopulated
    }()
}
