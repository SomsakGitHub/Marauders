//
//  WorkerDateParser.swift
//  Marauders
//

import Foundation

/// The Worker writes `Date.toISOString()`, which carries milliseconds; `JSONDecoder.iso8601` rejects those.
nonisolated enum WorkerDateParser {
    static func date(from string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
