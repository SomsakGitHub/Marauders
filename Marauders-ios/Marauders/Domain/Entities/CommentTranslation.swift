//
//  CommentTranslation.swift
//  Marauders
//

import Foundation
import NaturalLanguage

/// Decides whether a comment offers a Translate button, and from which language. The translation itself runs on the
/// reader's iPhone (Apple Translation); the Worker only stores the original text.
enum CommentTranslation {
    /// Where a translation starts from.
    enum Source: Equatable {
        /// The comment declares this language, or the iPhone recognised it with confidence.
        case known(String)
        /// Too short or too mixed to be sure ("ok", "nice"): Apple Translation works out the language itself.
        case detectedByTranslation
    }

    /// How sure the on-device recognizer must be before its guess is handed to Apple Translation as the source.
    static let minimumConfidence = 0.6

    /// What the Translate button translates from, or nil when there is nothing to offer: the comment is in the
    /// viewer's language (declared, or the recognizer's best guess even when unsure), or it has no words at all.
    static func source(for comment: Comment, target: ListeningLanguage?) -> Source? {
        guard let target else { return nil }
        if let declared = comment.language, ListeningLanguage(identifier: declared) != nil {
            return baseCode(of: declared) == target.code ? nil : .known(declared)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
        // Emoji, numbers ("555") and punctuation give no hypothesis: there is nothing to translate.
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        let guess = best.key.rawValue
        // A short comment in the viewer's own language often gets an unsure guess of that language ("nice" is
        // 20% English); it stays without a button rather than offering a translation into itself.
        guard baseCode(of: guess) != target.code else { return nil }
        if best.value >= minimumConfidence, ListeningLanguage(identifier: guess) != nil { return .known(guess) }
        return .detectedByTranslation
    }

    /// The language comments open in for a viewer in this country (ISO 3166-1 code): its main language, "TH" is
    /// Thai and "US" English. Nil for an unknown country or one whose language the app cannot translate into.
    static func language(forCountry country: String?) -> ListeningLanguage? {
        guard let country, country.count == 2 else { return nil }
        return ListeningLanguage(identifier: Locale.Language(identifier: "und-\(country.uppercased())").maximalIdentifier)
    }

    /// "zh-Hans" and "es-MX" compare as "zh" and "es"; Norwegian variants share the Bokmål code the app uses.
    private static func baseCode(of code: String) -> String {
        ListeningLanguage(identifier: code)?.code ?? code
    }
}
