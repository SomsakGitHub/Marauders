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
/// symbol, a bracketed label such as "[BLANK_AUDIO]", a subtitle credit, a phrase repeated over and over.
/// Those are removed here, so the AI voice does not read them out. This is not a complete defence:
/// WhisperKit 1.1.1 reports no no-speech probability (it is fixed at 0), so a plausible stock phrase
/// written for silence ("Thank you.", "ご視聴ありがとうございました", "Đi nào?") is not caught, and the music tail of
/// the test clip was written with higher confidence than its speech. The limits are Whisper's own and a few
/// measurements (the Dutch test clip, and the same dialogue in 22 languages read by system voices with
/// noise, music and near silence added), not a calibration.
nonisolated enum AcousticTranscriptPolicy {
    /// A segment with a higher compression ratio is the model repeating itself (Whisper's own limit).
    static let loopRatio = 2.4
    /// Fewer letters than this is a symbol or a stray sound, not a word. (A single character that is a whole
    /// word in Chinese, Japanese or Korean, such as 好, therefore does not count on its own.)
    static let fewestLetters = 2
    /// The longest label the model writes for a sound ("[Tidak, berhenti di tempat kejutan]" is 34 characters);
    /// a longer stretch inside brackets is taken to be speech.
    static let longestLabel = 60

    /// Fragments that models trained on subtitled video write for silence and music: who made the subtitles,
    /// a channel's name or sign-off. Real speech almost never contains them, but a person talking about
    /// subtitles would lose that sentence. Matched in lower case, anywhere in a sentence.
    ///
    /// Provenance: "tv gelderland" (and the capital-letter rule below), "субтитр" with "корректор а." and the
    /// Vietnamese sign-off were seen in measurements, and "amara.org" and the Dutch, German, French, Spanish,
    /// Portuguese, Italian, Polish, Turkish and Scandinavian subtitle words come from the families Whisper
    /// models are widely reported to write. The Arabic, Chinese, Japanese, Korean and Indonesian entries and the
    /// names at the end are reported the same way and were not seen here. A marker that is also an ordinary
    /// word of its language was kept only when the word is a subtitle credit's word ("sottotitoli").
    static let creditMarkers = [
        // Any language
        "amara.org", "©", "www.", "http", "otter.ai",
        // English
        "subtitles by", "subtitled by", "captions by", "captioned by",
        // Dutch
        "ondertitel", "tv gelderland", "tt888",
        // German
        "untertitel", "stephanie geiges",
        // French
        "sous-titr", "sous titr", "soustitreur",
        // Spanish
        "subtítulos", "subtitulos", "subtitulado por",
        // Portuguese
        "legendas pela", "legendado por",
        // Italian
        "sottotitoli", "qtss",
        // Russian and Ukrainian
        "субтитр", "корректор а.", "dimatorzok",
        // Polish
        "napisy stworzone", "napisy wykonał", "tłumaczenie i napisy",
        // Turkish
        "altyazı", "altyazi",
        // Swedish, Danish and Norwegian
        "undertexter", "undertekster", "teksting av", "nicolai winther",
        // Arabic
        "نانسي قنقر", "ترجمة نانسي",
        // Chinese, Simplified and Traditional
        "字幕由", "字幕志愿者", "字幕志願者", "中文字幕", "优优独播剧场", "優優獨播劇場", "明镜与点点栏目", "明鏡與點點",
        // Japanese and Korean
        "字幕制作", "字幕提供", "자막 제공", "한글자막",
        // Vietnamese
        "phụ đề", "ghiền mì gõ", "bỏ lỡ những video",
        // Indonesian
        "subtitle oleh"
    ]

    /// Code points of the symbols that mark music; a segment holding one is music, not speech.
    private static let musicSymbols: Set<UInt32> = [0x2669, 0x266A, 0x266B, 0x266C, 0x1F3B5, 0x1F3B6, 0x1F3BC]

    static func transcript(from segments: [AcousticSegment]) -> AcousticTranscript {
        var texts: [String] = []
        var weightedLogProbability = 0.0
        var letters = 0
        for segment in segments {
            let written = cleaned(segment.text)
            guard segment.compressionRatio <= loopRatio, !isMusic(written) else { continue }
            // A copyright line goes first, because its sign is in brackets that the next step strips. Credits go
            // after the labels: a label that holds one ("[Ondertiteld door NPO]") goes whole and leaves the speech
            // around it, and a credit can stand alone only once the label before it is gone ("[Muziek] NPO 2021.").
            let text = droppingCredits(from: withoutLabels(droppingCopyrightLines(from: written)))
            let count = letterCount(text)
            guard count >= fewestLetters else { continue }
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
        withoutSpeakerDashes(text.replacing(/<\|[^|]*\|>/, with: " "))
    }

    /// The text without the labels the model writes for sounds that are not speech: "[BLANK_AUDIO]",
    /// "* Musik *", "**Musik**", "(Applaus)", "（音楽）", "【音楽】", with the speaker's dash that may stand in
    /// front of one. Only closed labels of at most `longestLabel` characters go, innermost first, and whatever
    /// stands around them stays. A star pair that holds a digit is arithmetic ("5 * 3 * 4"), not a label.
    /// A parenthetical remark in real speech goes with them, which is accepted: the model writes sounds that
    /// way far more often than remarks.
    static func withoutLabels(_ text: String) -> String {
        var result = text
        for _ in 0..<5 {
            let stripped = result
                .replacing(/[-–—]*\[[^\[\]]{0,60}\]/, with: " ")
                .replacing(/[-–—]*\([^()]{0,60}\)/, with: " ")
                .replacing(/[-–—]*（[^（）]{0,60}）/, with: " ")
                .replacing(/[-–—]*【[^【】]{0,60}】/, with: " ")
                .replacing(/[-–—]*\*+[^*\d]{0,60}\*+/, with: " ")
            if stripped == result { break }
            result = stripped
        }
        return withoutSpeakerDashes(result)
    }

    private static func withoutSpeakerDashes(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { token -> Substring in
                let rest = token.drop { "-–—".contains($0) }
                return rest.first?.isLetter == true ? rest : token
            }
            .joined(separator: " ")
    }

    private static func isMusic(_ text: String) -> Bool {
        text.unicodeScalars.contains { musicSymbols.contains($0.value) }
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
            default: false
            }
        }.count
    }

    /// The text without its sentences that are credits. A credit stuck to a sentence of speech in one segment
    /// takes only its own sentence with it.
    private static func droppingCredits(from text: String) -> String {
        sentences(of: text).filter { !isCredit($0) }.map(String.init).joined()
    }

    /// The sentences of `text`, each with the space before it. A full stop ends one only before a space or at the
    /// end, so "А.Егорова" stays whole; the full-width stops of Chinese and Japanese end one anywhere.
    private static func sentences(of text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            let ends = "。！？".contains(character) || (".!?".contains(character) && (next == text.endIndex || text[next].isWhitespace))
            if ends {
                result.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// The text without a sentence that opens with "(C)", the copyright sign written in letters.
    private static func droppingCopyrightLines(from text: String) -> String {
        sentences(of: text).filter { !$0.drop { $0.isWhitespace }.lowercased().hasPrefix("(c)") }.map(String.init).joined()
    }

    private static func isCredit(_ sentence: Substring) -> Bool {
        let lowered = sentence.lowercased()
        return creditMarkers.contains { lowered.contains($0) } || isCapitalisedCredit(sentence)
    }

    /// A broadcaster or company name in capitals followed by a year ("TV GELDERLAND 2021."), which is how a
    /// copyright line reads: every letter is a capital and a number of exactly four digits starts with 19 or 20.
    /// A sentence in Chinese or Japanese that names an acronym and a year holds letters that have no case, so it
    /// is not touched, and neither is "In 2021 we went", which has lower-case letters.
    private static func isCapitalisedCredit(_ sentence: Substring) -> Bool {
        let letters = sentence.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else { return false }
        return sentence.matches(of: /[0-9]+/).contains { run in
            let digits = run.output
            return digits.count == 4 && (digits.hasPrefix("19") || digits.hasPrefix("20"))
        }
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
