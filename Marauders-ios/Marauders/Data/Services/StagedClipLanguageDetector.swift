import Foundation
import NaturalLanguage

/// Turns a transcript into a language guess. A transcript only counts when the speech recognizer
/// was reasonably sure and the text itself reads as the requested language, so a recognizer
/// forced onto the wrong language produces no evidence instead of a confident wrong answer.
enum LanguageEvidence {
    static func infer(text: String, speechConfidence: Double, requestedLanguage: String) -> SpeechLanguageDetection? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 12, speechConfidence >= 0.45 else { return nil }
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        guard let best = detector.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.key.rawValue.split(separator: "-").first.map({ String($0).lowercased() }) == requestedLanguage,
              best.value >= 0.8 else { return nil }
        return SpeechLanguageDetection(code: requestedLanguage, confidence: min(best.value, speechConfidence))
    }
}

extension LanguageEvidence {
    /// The least confidence a transcript from the Whisper model needs before it is translated.
    static let plausibleConfidence = 0.4

    /// Whether a whole transcript from an engine with no other cross-check really is `languageCode`: it was
    /// heard with some confidence and, once there is enough text to judge, NaturalLanguage reads it as that
    /// language. A few words are accepted on confidence alone, because a very short clip says too little.
    static func transcriptIsPlausible(text: String, confidence: Double, languageCode: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3, confidence >= plausibleConfidence else { return false }
        guard letters >= 12 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }) else { return false }
        return best.key.rawValue.split(separator: "-").first.map { String($0).lowercased() } == languageCode && best.value >= 0.6
    }
}

/// Recognizes a sample as one candidate language. A seam so the staging logic can be tested.
protocol SpeechEvidenceProviding {
    /// Candidates this iPhone can recognize right now without downloading anything.
    func installed(_ candidates: [SpeechLanguageCandidate]) async -> [SpeechLanguageCandidate]
    /// Transcribes `sample` as `candidate` and reports the language the text reads as, or nil when
    /// nothing usable came out. May download that language's speech model when `allowsDownload`.
    func evidence(for candidate: SpeechLanguageCandidate, sample: URL, allowsDownload: Bool) async -> SpeechLanguageDetection?
}

/// Detects the spoken language by recognizing a short sample as each candidate and checking what
/// language the transcript really is. Not acoustic language identification: it can only name a
/// language this iPhone has a recognizer for.
///
/// Languages whose models are already installed go first, all at once. Only if that is not
/// conclusive do the others get a turn, which may download a model the viewer does not have yet,
/// so an English clip never makes a phone fetch a Spanish model.
final class StagedClipLanguageDetector: ClipLanguageDetecting {
    /// Evidence from installed models is accepted on its own only at or above this confidence.
    static let earlyAcceptance = 0.8
    /// Another language this close behind the best one makes the result ambiguous.
    static let ambiguityMargin = 0.15
    /// The viewer's own language is tried only to say "this clip is already in it". A recognizer forced
    /// onto a close relative (German on a Dutch clip scored 0.51) produces believable text at middling
    /// confidence, so a language the app cannot dub from needs at least this much on its own. A heuristic,
    /// set between that one measurement and the confidence real speech in the right language reaches.
    static let ownLanguageFloor = 0.65

    private let provider: any SpeechEvidenceProviding

    init(provider: (any SpeechEvidenceProviding)? = nil) {
        self.provider = provider ?? SystemSpeechEvidence()
    }

    func detect(sample: URL, among candidates: [SpeechLanguageCandidate]) async -> SpeechLanguageDetection? {
        guard !candidates.isEmpty else { return nil }
        let ready = await provider.installed(candidates)
        var evidence = await gather(ready, sample: sample, allowsDownload: false)
        if let best = Self.decide(evidence), best.confidence >= Self.earlyAcceptance { return best }
        let remaining = candidates.filter { !ready.contains($0) }
        if !remaining.isEmpty, !Task.isCancelled {
            evidence += await gather(remaining, sample: sample, allowsDownload: true)
        }
        guard !Task.isCancelled else { return nil }
        return Self.decide(evidence)
    }

    /// Runs the candidates together, so the wait is the slowest one rather than their sum.
    private func gather(_ candidates: [SpeechLanguageCandidate], sample: URL, allowsDownload: Bool) async -> [SpeechLanguageDetection] {
        let provider = provider
        let tasks = candidates.map { candidate in
            Task { await provider.evidence(for: candidate, sample: sample, allowsDownload: allowsDownload) }
        }
        return await withTaskCancellationHandler {
            var found: [SpeechLanguageDetection] = []
            for task in tasks { if let item = await task.value { found.append(item) } }
            return found
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    /// The most confident language, or nil when a different language is nearly as likely, or when it is a
    /// language we cannot dub from and its evidence is below `ownLanguageFloor`.
    static func decide(_ evidence: [SpeechLanguageDetection]) -> SpeechLanguageDetection? {
        let sorted = evidence.sorted { $0.confidence > $1.confidence }
        guard let best = sorted.first else { return nil }
        if let other = sorted.dropFirst().first(where: { $0.code != best.code }),
           best.confidence - other.confidence < ambiguityMargin { return nil }
        if DubbingSourceLanguage(code: best.code) == nil, best.confidence < ownLanguageFloor { return nil }
        return best
    }
}
