//
//  FirebaseAppConfigRepository.swift
//  Marauders
//

import Foundation

/// Turns the two texts of Firebase Remote Config into the gate's `AppConfig` and keeps the last good one in
/// UserDefaults, so the next launch can decide with no fetch at all (docs/adr/012-force-update.md). Only an answer
/// replaces it: every failure, a cancellation included, answers nil and leaves what is kept as it was, which is what
/// keeps a build that already knows "update required" stopped while Firebase cannot be reached.
///
/// The minimum is read by the rule of the build's own number (`BuildNumber.parse`): digits only, and every other text,
/// an empty one or a parameter that is not published included, counts as 0, which is no gate. A link that is empty
/// is none; whether a link is good enough to send someone to is `UpdateDecision`'s rule, not this one's.
///
/// Logs under `update`, nothing that identifies a person: `config refreshed: minimumBuild=<n> (<where the SDK got it:
/// Google, or its saved values>)`, or `config refresh failed` (the source logs why).
struct FirebaseAppConfigRepository: AppConfigRepository {
    /// Where the answer is kept (JSON of an `AppConfig`). The `v1` is the shape: a later shape takes a new key.
    static let defaultsKey = "update.appConfig.v1"

    private let source: any RemoteConfigSource
    private let defaults: UserDefaults

    init(source: any RemoteConfigSource, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
    }

    /// The kept answer, read at once. An entry that no longer decodes counts as none and is removed.
    func cached() -> AppConfig? {
        guard let stored = defaults.object(forKey: Self.defaultsKey) else {
            return nil
        }
        if let data = stored as? Data, let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        defaults.removeObject(forKey: Self.defaultsKey)
        AppLog.warning("update", "kept config unreadable, removed")
        return nil
    }

    func refresh() async -> AppConfig? {
        // The SDK's fetch cannot be cancelled, so it may answer after the task that asked is cancelled: drop it.
        guard let values = await source.fetch(), !Task.isCancelled else {
            AppLog.warning("update", "config refresh failed")
            return nil
        }
        let config = AppConfig(
            minimumBuild: BuildNumber.parse(values.minimumBuild) ?? 0,
            updateURL: Self.link(from: values.updateURL))
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        let origin = values.origin.map { " (\($0.logText(now: Date())))" } ?? ""
        AppLog.info("update", "config refreshed: minimumBuild=\(config.minimumBuild)\(origin)")
        return config
    }

    private static func link(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }
}
