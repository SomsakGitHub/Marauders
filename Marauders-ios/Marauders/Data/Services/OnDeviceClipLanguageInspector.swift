import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// Best-effort language inference from short, local speech transcripts, not acoustic language ID.
@MainActor final class OnDeviceClipLanguageInspector: ClipLanguageInspecting {
    /// Off by default so an upload never waits on an Apple model download; users install
    /// models ahead of time from Settings → Language models.
    private let allowsModelDownload: Bool

    init(allowsModelDownload: Bool = false) {
        self.allowsModelDownload = allowsModelDownload
    }

    func inspect(fileURL: URL) async -> SpokenLanguageAssessment {
        guard fileURL.isFileURL else { return .unknown("unreadable") }
        let permission: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
            }
        } else { permission = SFSpeechRecognizer.authorizationStatus() }
        guard permission == .authorized else { return .unknown("permission_denied") }
        let identifiers = ["en-US", "th-TH"] + Locale.preferredLanguages
        var languages = Set<String>()
        let candidates = identifiers.compactMap { identifier -> SFSpeechRecognizer? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                  recognizer.supportsOnDeviceRecognition, recognizer.isAvailable,
                  let language = recognizer.locale.language.languageCode?.identifier,
                  languages.insert(language).inserted else { return nil }
            return recognizer
        }.prefix(3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let sample = try await SpeechAudioPreparation.chunks(from: fileURL, directory: folder, maximumSampleSeconds: 8).first else {
                return .unknown("no_speech")
            }
            let duration = min(8, try await AVURLAsset(url: sample).load(.duration).seconds)
            // Recognizers and the Spanish analyzer are independent, so run them together:
            // the wait is the slowest one, not their sum.
            let recognitions = candidates.map { recognizer in
                Task { () -> SpokenLanguageAssessment? in
                    let worker = LanguageSampleRecognizer()
                    guard let transcript = await worker.recognize(sample, using: recognizer) else { return nil }
                    return Self.infer(text: transcript.text, speechConfidence: transcript.confidence,
                                      requestedLanguage: recognizer.locale.language.languageCode?.identifier ?? "")
                }
            }
            let allowsDownload = allowsModelDownload
            let spanish = Task { () -> SpokenLanguageAssessment? in
                do { return try await SpanishLanguageAnalyzer.infer(sample: sample, downloadModelIfNeeded: allowsDownload) }
                catch is CancellationError { return nil }
                catch {
                    AppLog.warning("upload.language", "Spanish speech model or analysis unavailable; keeping uncertain result")
                    return nil
                }
            }
            let evidence = await withTaskCancellationHandler {
                var found: [SpokenLanguageAssessment] = []
                for task in recognitions { if let item = await task.value { found.append(item) } }
                if let item = await spanish.value { found.append(item) }
                return found
            } onCancel: {
                recognitions.forEach { $0.cancel() }
                spanish.cancel()
            }
            try Task.checkCancellation()
            var result = Self.combine(evidence)
            result.sampledSeconds = duration.isFinite ? duration : 0
            return result
        } catch { return .unknown(Task.isCancelled ? "cancelled" : "unreadable") }
    }

    static func infer(text: String, speechConfidence: Double, requestedLanguage: String) -> SpokenLanguageAssessment? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 12, speechConfidence >= 0.45 else { return nil }
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        guard let best = detector.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.key.rawValue.split(separator: "-").first.map(String.init) == requestedLanguage, best.value >= 0.8 else { return nil }
        return .init(status: "likely", code: best.key.rawValue.lowercased(), confidence: min(best.value, speechConfidence))
    }
    static func combine(_ evidence: [SpokenLanguageAssessment]) -> SpokenLanguageAssessment {
        let sorted = evidence.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        guard let best = sorted.first else { return .unknown("not_recognized") }
        if let other = sorted.dropFirst().first(where: { $0.code != best.code }),
           (best.confidence ?? 0) - (other.confidence ?? 0) < 0.15 { return .unknown("ambiguous") }
        return best
    }
}

private struct LanguageTranscript { let text: String; let confidence: Double }

@MainActor private final class LanguageSampleRecognizer {
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<LanguageTranscript?, Never>?
    private var latest: LanguageTranscript?
    func recognize(_ url: URL, using recognizer: SFSpeechRecognizer) async -> LanguageTranscript? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    self?.finish()
                }
                task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let segments = result?.bestTranscription.segments ?? []
                    let confidence = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
                    let ended = result?.isFinal == true || error != nil
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        if let text, !text.isEmpty { self.latest = LanguageTranscript(text: text, confidence: confidence) }
                        if ended { self.finish() }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(cancelled: true) } }
    }
    private func finish(cancelled: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        task?.cancel()
        continuation.resume(returning: cancelled ? nil : latest)
    }
}
