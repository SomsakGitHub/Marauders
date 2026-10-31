//
//  CommentTranslation.swift
//  Marauders
//

import Foundation
import NaturalLanguage

/// Decides whether a comment offers a Translate button, and from which language. The translation itself runs on the
/// reader's iPhone (Apple Translation); the Worker only stores the original text.
enum CommentTranslation {
    /// Language detection on a few characters is a guess, so shorter text is not offered for translation.
    static let minimumDetectionCharacters = 12
    /// How sure the on-device recognizer must be of a detected language.
    static let minimumConfidence = 0.6

    /// The language code to translate from, or nil when there is nothing to offer: the comment is already in the
    /// viewer's language, its language is unknown, or it is not one Apple Translation handles for dubbing.
    static func sourceCode(for comment: Comment, target: ListeningLanguage?) -> String? {
        guard let target else { return nil }
        guard let source = declaredOrDetectedCode(for: comment) else { return nil }
        guard baseCode(of: source) != target.code else { return nil }
        return source
    }

    private static func declaredOrDetectedCode(for comment: Comment) -> String? {
        if let declared = comment.language, ListeningLanguage(identifier: declared) != nil { return declared }
        let text = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommentRules.characterCount(text) >= minimumDetectionCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumConfidence,
              ListeningLanguage(identifier: best.key.rawValue) != nil
        else { return nil }
        return best.key.rawValue
    }

    /// "zh-Hans" and "es-MX" compare as "zh" and "es"; Norwegian variants share the Bokmål code the app uses.
    private static func baseCode(of code: String) -> String {
        ListeningLanguage(identifier: code)?.code ?? code
    }
}
