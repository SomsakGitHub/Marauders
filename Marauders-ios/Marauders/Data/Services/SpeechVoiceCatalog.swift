import AVFoundation
import Foundation

/// Chooses the system speech voice that reads translated narration aloud.
enum SpeechVoiceCatalog {
    struct Candidate: Equatable, Sendable {
        let identifier: String
        /// BCP-47 tag such as "pt-BR".
        let language: String
        /// `AVSpeechSynthesisVoiceQuality` raw value: 1 default, 2 enhanced, 3 premium.
        let quality: Int
    }

    /// Languages whose regions sound quite different keep a conventional default.
    private static let preferredRegions = ["ar": "SA", "de": "DE", "en": "US", "es": "ES", "fr": "FR", "pt": "BR", "zh": "CN"]

    static func candidates(_ voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> [Candidate] {
        voices.map { Candidate(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue) }
    }

    /// The best installed voice's language tag: the language's usual region first, then higher quality.
    /// Novelty voices (Eloquence, "Bad News", bells) are never chosen.
    static func bestLanguageTag(for language: ListeningLanguage, among candidates: [Candidate]) -> String? {
        let region = preferredRegions[language.code]
        func rank(_ candidate: Candidate) -> Int {
            Locale(identifier: candidate.language).region?.identifier == region ? 0 : 1
        }
        return candidates
            .filter { ListeningLanguage(identifier: $0.language) == language && !isNovelty($0.identifier) }
            .sorted { lhs, rhs in
                if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.identifier < rhs.identifier
            }
            .first?.language
    }

    /// The system's own default voice for the best language tag, so the viewer's voice settings apply.
    static func voice(for language: ListeningLanguage) -> AVSpeechSynthesisVoice? {
        guard let tag = bestLanguageTag(for: language, among: candidates()) else { return nil }
        return AVSpeechSynthesisVoice(language: tag)
    }

    private static func isNovelty(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.eloquence") || identifier.hasPrefix("com.apple.speech.synthesis.voice")
    }
}
