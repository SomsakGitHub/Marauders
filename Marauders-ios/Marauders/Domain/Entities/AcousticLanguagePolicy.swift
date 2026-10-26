//
//  AcousticLanguagePolicy.swift
//  Marauders
//

import Foundation

/// What an acoustic model heard in one window of a clip: a language label and how sure it is (0 to 1).
nonisolated struct AcousticLanguageGuess: Equatable, Sendable {
    let code: String
    let probability: Double
}

/// Decides when what an acoustic model heard is trustworthy enough to act on.
///
/// The thresholds come from a small measurement (one real clip and synthetic speech), not from a
/// calibration on real clips, so treat them as a first guess.
nonisolated enum AcousticLanguagePolicy {
    /// Mean probability over the windows that a guess needs before the app acts on it.
    static let acceptance = 0.8

    /// An answer below this is acted on for this clip but not remembered, so a wrong label cannot hide the
    /// audio button for good: the viewer can try again, and a better detector gets another chance.
    static let rememberAbove = 0.95

    /// Languages the app is willing to name. The model knows about ninety-nine; a label outside this
    /// list is more likely a mistake than a real language, and it would be shown to the viewer verbatim.
    static let namedLanguages: Set<String> = [
        "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fil", "fr",
        "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi", "yue", "zh"
    ]

    /// The model's label as one of the app's language codes, or nil when the app does not name it.
    /// Norwegian comes back as "no" or "nn"; both mean Bokmål here, like everywhere else in the app.
    static func appCode(forModelLabel label: String) -> String? {
        let code = switch label.lowercased() {
        case "no", "nn": "nb"
        case "tl": "fil"
        case "iw": "he"
        case let other: other
        }
        return namedLanguages.contains(code) ? code : nil
    }

    /// The language to act on, or nil. Every window must name the same language, and the mean
    /// probability must reach `acceptance`, so one confident window cannot overrule another that disagrees.
    static func decide(_ guesses: [AcousticLanguageGuess]) -> AcousticLanguageGuess? {
        guard !guesses.isEmpty else { return nil }
        var agreed: String?
        var total = 0.0
        for guess in guesses {
            guard let code = appCode(forModelLabel: guess.code) else { return nil }
            if let agreed, agreed != code { return nil }
            agreed = code
            total += guess.probability
        }
        guard let agreed else { return nil }
        let mean = total / Double(guesses.count)
        return mean >= acceptance ? AcousticLanguageGuess(code: agreed, probability: mean) : nil
    }
}
