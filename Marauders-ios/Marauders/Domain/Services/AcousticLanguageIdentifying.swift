//
//  AcousticLanguageIdentifying.swift
//  Marauders
//

import Foundation

/// Names the language a short stretch of speech is in by listening to it, without transcribing it,
/// on the viewer's iPhone.
nonisolated protocol AcousticLanguageIdentifying: Sendable {
    /// What the model hears in `window` (a short 16 kHz mono file), or nil when the model is not on
    /// this iPhone or could not run.
    func identify(window: URL) async -> AcousticLanguageGuess?
}

nonisolated struct NoopAcousticLanguageIdentifier: AcousticLanguageIdentifying {
    func identify(window: URL) async -> AcousticLanguageGuess? { nil }
}

/// Asks an identifier about each window of a clip and applies `AcousticLanguagePolicy`.
nonisolated struct AcousticClipLanguageDetector: Sendable {
    let identifier: any AcousticLanguageIdentifying

    /// The language the windows agree on, or nil when they disagree, are unsure or the model could not run.
    func detect(windows: [URL]) async -> AcousticLanguageGuess? {
        var guesses: [AcousticLanguageGuess] = []
        for window in windows {
            if Task.isCancelled { return nil }
            if let guess = await identifier.identify(window: window) { guesses.append(guess) }
        }
        return AcousticLanguagePolicy.decide(guesses)
    }
}
