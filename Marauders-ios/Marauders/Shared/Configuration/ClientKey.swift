//
//  ClientKey.swift
//  Marauders
//

import Foundation

/// The one value the build hands the app (`MARAUDERS_CLIENT_KEY`), and the pass the app needs in order to run: it
/// starts only when the value is exactly `run by pass` (`MaraudersApp` checks it before anything else and shows a block
/// screen otherwise). The project holds the pass in the build settings of both app configurations, which is why a plain
/// Run from Xcode needs no setup; Jenkins overrides it for a TestFlight build (docs/ci-cd.md), and its credential must
/// hold the pass too. The value reaches the app the way `MARAUDERS_API_BASE_URL` does: the build setting fills the
/// Info.plist key of the same name (`Config/Info-Additions.plist`) and `resolved()` reads it.
///
/// Nothing sends it anywhere: the app only compares it. Wherever a value is turned into text it prints as
/// `<redacted>`, so a log line, a `dump` or a debugger never shows it. It is not a secret: the pass is in git and in the
/// app, so this is a gate that shows the value arrived, not protection.
///
/// nonisolated (the app target's default is the main actor) so the background-task closure of `MaraudersApp`, which
/// runs off the main actor, can ask `appMayRun()`.
nonisolated struct ClientKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The Info.plist key and the build setting both carry this name.
    static let configKey = "MARAUDERS_CLIENT_KEY"

    /// The one value that lets the app run, exactly as typed: lower case, single spaces.
    static let pass = "run by pass"

    /// Trimmed, not blank and free of control characters: `resolve(configured:)` is the only way to make one.
    let value: String

    private init(value: String) {
        self.value = value
    }

    /// The rule behind `resolved()`, without a bundle. No key when `configured` is missing or blank, when it is the
    /// text of a build setting that was never filled in (`$(MARAUDERS_CLIENT_KEY)`), or when it holds a control
    /// character (a line break would start another header or another command-line word).
    static func resolve(configured: String?) -> ClientKey? {
        guard let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard !trimmed.hasPrefix("$("), trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return ClientKey(value: trimmed)
    }

    /// Whether `configured` is the pass: the rule behind `appMayRun()`, without a bundle. `resolve(configured:)` goes
    /// first, so surrounding whitespace is ignored and a missing or blank value, an unexpanded `$(…)` and one with a
    /// control character are refused; then the comparison is exact, so another case, another spacing and extra words
    /// are refused too.
    static func accepts(configured: String?) -> Bool {
        resolve(configured: configured)?.value == pass
    }

    /// The key this build carries: the `MARAUDERS_CLIENT_KEY` key of Info.plist. None when it is missing or unusable.
    /// It logs nothing.
    static func resolved() -> ClientKey? {
        resolve(configured: Bundle.main.object(forInfoDictionaryKey: configKey) as? String)
    }

    /// Whether this build may run: the `MARAUDERS_CLIENT_KEY` key of Info.plist is the pass. Read from the bundle on
    /// every call (one dictionary lookup), so nothing caches the decision. It logs nothing.
    static func appMayRun() -> Bool {
        accepts(configured: Bundle.main.object(forInfoDictionaryKey: configKey) as? String)
    }

    var description: String { "ClientKey(value: <redacted>)" }

    var debugDescription: String { description }

    /// What `dump` and a debugger show: a placeholder, never the value.
    var customMirror: Mirror {
        Mirror(self, children: ["value": "<redacted>"], displayStyle: .struct)
    }
}
