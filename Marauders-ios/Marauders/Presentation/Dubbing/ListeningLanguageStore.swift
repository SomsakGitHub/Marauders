//
//  ListeningLanguageStore.swift
//  Marauders
//

import Foundation
import Observation

/// The languages a viewer wants to hear clips in. A viewer's explicit choice wins; otherwise
/// the device languages we can dub into are offered, minus the clip's own language, since
/// someone who lists English already understands an English clip.
@MainActor
@Observable
final class ListeningLanguageStore {
    static let shared: ListeningLanguageStore = {
        // UI tests get a fixed English + Thai viewer and never read or keep a saved choice.
        if AppRuntimeConfiguration.isUITesting {
            let suite = "marauders.uitest.listening"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return ListeningLanguageStore(defaults: defaults, preferredLanguages: { ["en-US", "th-TH"] })
        }
        return ListeningLanguageStore()
    }()

    private static let defaultsKey = "listeningLanguage"

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private let memo: DetectedLanguageMemo
    private(set) var explicit: ListeningLanguage?

    init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        memo: DetectedLanguageMemo? = nil
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.memo = memo ?? DetectedLanguageMemo.shared
        explicit = defaults.string(forKey: Self.defaultsKey).flatMap { ListeningLanguage(identifier: $0) }
    }

    /// Device languages we can dub into, in the viewer's order of preference.
    var supportedDeviceLanguages: [ListeningLanguage] {
        var seen = Set<String>()
        return preferredLanguages()
            .compactMap { ListeningLanguage(identifier: $0) }
            .filter { seen.insert($0.code).inserted }
    }

    /// What Settings shows: the explicit choice, or the first supported device language.
    var effective: ListeningLanguage? { explicit ?? supportedDeviceLanguages.first }

    /// Every language a dubbed clip might be translated into for this viewer.
    var possibleTargets: [ListeningLanguage] {
        if let explicit { return [explicit] }
        return supportedDeviceLanguages
    }

    func choose(_ language: ListeningLanguage?) {
        explicit = language
        if let language { defaults.set(language.code, forKey: Self.defaultsKey) }
        else { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    /// The language a clip is declared to speak: the uploader's choice (or an older upload-time guess),
    /// else what this iPhone's own detection found earlier. Nil when nobody knows yet.
    func declaredCode(for clip: FeedVideo) -> String? {
        clip.declaredSourceCode ?? memo.code(for: clip.id)
    }

    /// Languages to offer for a clip: all the viewer listens in, except the clip's own language
    /// when that is known (hearing it dubbed into itself would change nothing).
    func targets(for clip: FeedVideo) -> [ListeningLanguage] {
        let declared = declaredCode(for: clip)
        return possibleTargets.filter { $0.code != declared }
    }

    /// Whether to show the audio-choice entry point for a clip.
    func offersDubbing(for clip: FeedVideo) -> Bool {
        guard clip.allowsAIAudio else { return false }
        // A known language we cannot dub from yet is a dead end, so there is nothing to offer.
        if let declared = declaredCode(for: clip), DubbingSourceLanguage(code: declared) == nil { return false }
        if !targets(for: clip).isEmpty { return true }
        // A viewer with no language we support can still open the picker and choose one.
        return explicit == nil && supportedDeviceLanguages.isEmpty
    }
}
