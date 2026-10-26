//
//  AcousticTranscriptPolicy.swift
//  Marauders
//

import Foundation

/// One stretch of speech an acoustic model wrote down, with the model's own signs of how much to trust it.
nonisolated struct AcousticSegment: Equatable, Sendable {
    let text: String
    /// Mean log probability of the tokens of the decoding window the segment came from (0 at best, more
    /// negative when the model is unsure). WhisperKit gives every segment of a window the window's value, and
    /// the mean includes the forced prompt tokens, so it flatters short texts.
    let averageLogProbability: Double
    /// How well the window's text compresses; a model stuck in a loop repeats itself and scores high.
    let compressionRatio: Double
}

/// What an acoustic model wrote down for a clip: the text, and how confident it was (0 to 1).
nonisolated struct AcousticTranscript: Equatable, Sendable {
    let text: String
    let confidence: Double
}

/// Turns what an acoustic model wrote for a clip into text worth translating.
///
/// A model that always writes something also writes something for music, noise and silence: a note
/// symbol, a subtitle credit, a phrase repeated over and over. Some of those are removed here, so the AI
/// voice does not read them out. This is not a complete defence: WhisperKit 1.1.1 reports no no-speech
/// probability (it is fixed at 0), so a plausible stock phrase written for silence is not caught here, and
/// the music tail of the test clip was written with higher confidence than its speech. The limits are
/// Whisper's own and one measurement, not a calibration.
nonisolated enum AcousticTranscriptPolicy {
    /// A segment with a higher compression ratio is the model repeating itself (Whisper's own limit).
    static let loopRatio = 2.4
    /// Fewer letters than this is a symbol or a stray sound, not a word.
    static let fewestLetters = 2

    /// Fragments that models trained on subtitled video write for silence and music in many languages.
    /// Real speech almost never contains them. A measured example: Whisper small ended the Dutch test
    /// clip, after its last word, with "(C) TV GELDERLAND 2020".
    static let creditMarkers = [
        "amara.org", "ondertitel", "untertitel", "subtitles by", "sous-titr", "subtítulos", "©", "(c) ", "www.", "http"
    ]

    static func transcript(from segments: [AcousticSegment]) -> AcousticTranscript {
        var texts: [String] = []
        var weightedLogProbability = 0.0
        var letters = 0
        for segment in segments {
            let text = cleaned(segment.text)
            let count = letterCount(text)
            guard count >= fewestLetters,
                  segment.compressionRatio <= loopRatio,
                  !looksLikeCredit(text) else { continue }
            texts.append(text)
            weightedLogProbability += segment.averageLogProbability * Double(count)
            letters += count
        }
        guard letters > 0 else { return AcousticTranscript(text: "", confidence: 0) }
        return AcousticTranscript(text: texts.joined(separator: " "), confidence: exp(weightedLogProbability / Double(letters)))
    }

    /// The text without the control tokens (`<|0.00|>`) Whisper can leave in, with tidy spacing and without the
    /// dash it puts in front of a new speaker's turn ("-Ja, natuurlijk."), which a voice or a translator
    /// could take for something to say.
    static func cleaned(_ text: String) -> String {
        text.replacing(/<\|[^|]*\|>/, with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { token -> Substring in
                let rest = token.drop { "-–—".contains($0) }
                return rest.first?.isLetter == true ? rest : token
            }
            .joined(separator: " ")
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    private static func looksLikeCredit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return creditMarkers.contains { lowered.contains($0) }
    }
}

/// Writes down what a clip says, on the viewer's iPhone.
nonisolated protocol AcousticTranscribing: Sendable {
    /// What the model hears in the audio of `file` (a clip, in any format AVFoundation reads), start to
    /// end, when it is told the language is `languageCode`. The text is empty when the model heard no
    /// speech. Nil when the model is not on this iPhone. Throws when the model could not run, or when the
    /// calling task is cancelled.
    func transcribe(file: URL, languageCode: String) async throws -> AcousticTranscript?
}
