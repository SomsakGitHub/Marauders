//
//  DubbingSourceLanguage.swift
//  Marauders
//

import Foundation

/// Languages the on-device pipeline can transcribe and translate into a viewer's language.
enum DubbingSourceLanguage: String, Hashable, Sendable, CaseIterable {
    case english
    case spanish

    /// BCP-47 language code for Apple Translation.
    var translationCode: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        }
    }

    var speechLocale: String {
        switch self {
        case .english: "en-US"
        case .spanish: "es-ES"
        }
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
