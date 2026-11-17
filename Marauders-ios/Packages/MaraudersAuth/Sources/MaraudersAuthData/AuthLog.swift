//
//  AuthLog.swift
//  MaraudersAuthData
//

import Foundation

/// The session module's log. The module keeps no log of its own: the app points `sink` at its log once, when it
/// launches, and every line goes there. Until then nothing is logged.
///
/// No line ever holds a token.
public enum AuthLog {
    public enum Level: Sendable {
        case info
        case warning
        case error
    }

    /// Where the lines go. The app sets it once, before anything that can log.
    public static var sink: (@MainActor (_ level: Level, _ category: String, _ message: String) -> Void)?

    static func info(_ category: String, _ message: String) {
        sink?(.info, category, message)
    }

    static func warning(_ category: String, _ message: String) {
        sink?(.warning, category, message)
    }

    static func error(_ category: String, _ message: String) {
        sink?(.error, category, message)
    }
}
