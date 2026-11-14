//
//  SystemSpeechTranscribing.swift
//  Marauders
//

import Foundation

/// What Apple's speech engine wrote down for a stretch of speech, and how sure it was (0 to 1).
struct SpeechTranscript: Sendable {
    let text: String
    let confidence: Double
}

/// Why a speech model could not be made ready, so the viewer is told the real reason.
nonisolated enum SpeechModelInstallError: Error, Equatable {
    /// The system lets an app keep only a few speech languages downloaded.
    case limitReached
    case downloadFailed
}

/// Writes down a short audio file with the speech engine Apple provides, entirely on the viewer's iPhone.
protocol SystemSpeechTranscribing {
    /// The words in `file`, which is spoken in the language of `localeIdentifier` (such as "es-ES"). Nil when that
    /// language is not supported, or its model is not on this iPhone and `downloadModelIfNeeded` is false. Throws
    /// `SpeechModelInstallError` when the model cannot be made ready, and when the calling task is cancelled.
    func transcribe(file: URL, localeIdentifier: String, downloadModelIfNeeded: Bool, timeout: Duration)
        async throws -> SpeechTranscript?
}
