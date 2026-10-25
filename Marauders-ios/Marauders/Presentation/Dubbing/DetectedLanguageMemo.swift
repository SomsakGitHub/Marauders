//
//  DetectedLanguageMemo.swift
//  Marauders
//

import Foundation
import Observation

/// Remembers, on this iPhone only, which language the viewer's own detection found in a clip, so the
/// audio button stops being offered for clips already in the viewer's language and the same clip
/// is not analysed twice. Oldest entries are dropped past `limit`.
@MainActor
@Observable
final class DetectedLanguageMemo {
    static let shared: DetectedLanguageMemo = {
        // UI tests start empty and never keep anything between runs.
        if AppRuntimeConfiguration.isUITesting {
            let suite = "marauders.uitest.detected"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return DetectedLanguageMemo(defaults: defaults)
        }
        return DetectedLanguageMemo()
    }()

    private static let key = "detectedClipLanguages"

    private let defaults: UserDefaults
    private let limit: Int
    /// Video ids, oldest first.
    private var order: [String]
    private var codes: [String: String]

    init(defaults: UserDefaults = .standard, limit: Int = 300) {
        self.defaults = defaults
        self.limit = limit
        let saved = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        let ids = saved["order"] ?? []
        let values = saved["codes"] ?? []
        // Ids and codes are stored side by side; anything that does not line up is treated as corrupt.
        if ids.count == values.count {
            order = ids
            codes = Dictionary(zip(ids, values)) { _, newer in newer }
        } else {
            order = []
            codes = [:]
        }
    }

    func code(for videoID: UUID) -> String? {
        codes[videoID.uuidString.lowercased()]
    }

    func remember(_ code: String, for videoID: UUID) {
        let id = videoID.uuidString.lowercased()
        if codes[id] != nil { order.removeAll { $0 == id } }
        codes[id] = code
        order.append(id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            codes[oldest] = nil
        }
        persist()
    }

    private func persist() {
        let ids = order.filter { codes[$0] != nil }
        defaults.set(["order": ids, "codes": ids.compactMap { codes[$0] }], forKey: Self.key)
    }
}
