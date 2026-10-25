//
//  SpeechLanguageCandidate.swift
//  Marauders
//

import Foundation

/// A language the viewer's iPhone can try to recognize in a clip, and the speech locale to use.
struct SpeechLanguageCandidate: Hashable, Sendable {
    /// Base BCP-47 language code ("en").
    let code: String
    /// Speech locale used to recognize it ("en-US").
    let locale: String

    /// The conventional speech locale for each language the app can recognize; nil for the rest
    /// (for example Danish), which cannot be told apart from a transcript.
    static func recognizable(_ code: String) -> SpeechLanguageCandidate? {
        let locales = [
            "de": "de-DE", "en": "en-US", "es": "es-ES", "fr": "fr-FR", "it": "it-IT",
            "ja": "ja-JP", "ko": "ko-KR", "pt": "pt-BR", "th": "th-TH", "zh": "zh-CN"
        ]
        return locales[code].map { SpeechLanguageCandidate(code: code, locale: $0) }
    }
}

/// The language a clip's speech was recognized as, with a heuristic (not calibrated) confidence.
struct SpeechLanguageDetection: Equatable, Sendable {
    let code: String
    let confidence: Double
}
