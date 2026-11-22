//
//  BuildNumber.swift
//  Marauders
//

import Foundation

/// The number of this build, which the force-update gate compares with the minimum build
/// (docs/adr/012-force-update.md). Jenkins numbers a TestFlight build (`BUILD_NUMBER` becomes `CURRENT_PROJECT_VERSION`
/// and so `CFBundleVersion`); every other build, a developer's own run included, is build 1, which the gate stops like
/// any other number (only a debug build is exempt).
///
/// nonisolated like `ClientKey` (the app target's default is the main actor), so a test or a background closure can ask
/// without hopping to the main actor.
nonisolated enum BuildNumber {
    /// The Info.plist key that holds the number.
    static let infoKey = "CFBundleVersion"

    /// The number in `text`: ASCII digits only (surrounding whitespace is ignored) that fit an `Int`. Nothing else
    /// counts, so a value such as `1.0`, `1b`, `-3` or an empty string is no number, and no number cannot stop an app.
    static func parse(_ text: String?) -> Int? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            trimmed.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else {
            return nil
        }
        return Int(trimmed)
    }

    /// The number of the running app: its `CFBundleVersion`. Nil when that is missing or not a whole number.
    static var current: Int? {
        parse(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// Whether this is a debug build (the `DEBUG` compilation condition, which the Debug configurations define).
    static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }
}
