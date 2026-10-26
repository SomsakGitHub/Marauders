//
//  DubbingSourceLanguage.swift
//  Marauders
//

import Foundation

/// The on-device engine that turns a language's speech into text.
nonisolated enum SpeechEngine: Hashable, Sendable {
    /// The older `SFSpeechRecognizer`, which the app uses for English.
    case recognizer
    /// iOS 26 `SpeechTranscriber`: a few languages, small models.
    case speechTranscriber
    /// The Whisper model that also names a clip's language (the language detection model): it writes
    /// down speech in many languages, Dutch among them, and needs no speech-recognition permission.
    case whisper
}

/// Languages the on-device pipeline can transcribe and translate into a viewer's language.
enum DubbingSourceLanguage: String, Hashable, Sendable, CaseIterable {
    case english
    case spanish
    case dutch

    /// BCP-47 language code for Apple Translation.
    var translationCode: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        case .dutch: "nl"
        }
    }

    var speechLocale: String {
        switch self {
        case .english: "en-US"
        case .spanish: "es-ES"
        case .dutch: "nl-NL"
        }
    }

    var speechEngine: SpeechEngine {
        switch self {
        case .english: .recognizer
        case .spanish: .speechTranscriber
        case .dutch: .whisper
        }
    }

    /// Whether the recognizers that detect a language without the detection model can recognize it.
    /// Dutch is found by the detection model and not by them: Apple's recognizers hear almost nothing
    /// of it, and the Whisper model is the one that transcribes it anyway.
    var isRecognizedWithoutDetectionModel: Bool { speechEngine != .whisper }

    /// What the recognizers try when the detection model is not on the iPhone.
    static var recognizerCandidates: [SpeechLanguageCandidate] {
        allCases.filter(\.isRecognizedWithoutDetectionModel).map(\.candidate)
    }

    /// The name in the viewer's language, used in progress and error messages.
    func displayName(in locale: Locale = ListeningLanguage.interfaceLocale) -> String {
        locale.localizedString(forLanguageCode: translationCode) ?? translationCode
    }

    /// The dubbing source for a language code such as "es" or "es-MX"; nil when we can't
    /// transcribe that language yet.
    init?(code: String) {
        let base = code.split(separator: "-").first.map { String($0).lowercased() } ?? ""
        guard let match = Self.allCases.first(where: { $0.translationCode == base }) else { return nil }
        self = match
    }

    /// How the viewer's iPhone recognizes this language when it has to work out what a clip speaks.
    var candidate: SpeechLanguageCandidate {
        SpeechLanguageCandidate(code: translationCode, locale: speechLocale)
    }
}
