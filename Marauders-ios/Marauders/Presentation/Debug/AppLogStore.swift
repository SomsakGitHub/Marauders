//
//  AppLogStore.swift
//  Marauders
//

import Foundation
import Observation
import os

enum AppLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct AppLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: AppLogLevel
    let category: String
    let message: String

    var formatted: String {
        let stamp = AppLogEntry.formatter.string(from: date)
        return "[\(stamp)] [\(level.rawValue)] [\(category)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

@MainActor
@Observable
final class AppLogStore {
    static let shared = AppLogStore()

    private(set) var entries: [AppLogEntry] = []
    private let maxEntries = 250

    private init() {}

    func debug(_ category: String, _ message: String) {
        append(.debug, category: category, message: message)
    }

    func info(_ category: String, _ message: String) {
        append(.info, category: category, message: message)
    }

    func warning(_ category: String, _ message: String) {
        append(.warning, category: category, message: message)
    }

    func error(_ category: String, _ message: String) {
        append(.error, category: category, message: message)
    }

    func clear() {
        entries.removeAll()
        info("app", "log cleared")
    }

    var exportText: String {
        if entries.isEmpty {
            return "(ไม่มีบันทึก)"
        }
        return entries.map(\.formatted).joined(separator: "\n")
    }

    private func append(_ level: AppLogLevel, category: String, message: String) {
        let entry = AppLogEntry(date: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Marauders", category: category)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}

enum AppLog {
    static func debug(_ category: String, _ message: String) {
        Task { @MainActor in
            AppLogStore.shared.debug(category, message)
        }
    }

    static func info(_ category: String, _ message: String) {
        Task { @MainActor in
            AppLogStore.shared.info(category, message)
        }
    }

    static func warning(_ category: String, _ message: String) {
        Task { @MainActor in
            AppLogStore.shared.warning(category, message)
        }
    }

    static func error(_ category: String, _ message: String) {
        Task { @MainActor in
            AppLogStore.shared.error(category, message)
        }
    }
}
