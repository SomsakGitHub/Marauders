import Foundation
import Speech

/// Recognizes a sample with the iOS 26 `SpeechAnalyzer` when that language's model is installed,
/// else with the on-device `SFSpeechRecognizer`; a missing analyzer model is downloaded only when
/// the caller allows it. If one route produces nothing the next is tried. Audio and text never
/// leave the iPhone.
final class SystemSpeechEvidence: SpeechEvidenceProviding {
    private enum Route {
        case analyzer
        case legacy(SFSpeechRecognizer)
    }

    func installed(_ candidates: [SpeechLanguageCandidate]) async -> [SpeechLanguageCandidate] {
        var ready: [SpeechLanguageCandidate] = []
        for candidate in candidates where !(await routes(for: candidate, allowsDownload: false)).isEmpty {
            ready.append(candidate)
        }
        return ready
    }

    func evidence(for candidate: SpeechLanguageCandidate, sample: URL, allowsDownload: Bool) async -> SpeechLanguageDetection? {
        let routes = await routes(for: candidate, allowsDownload: allowsDownload)
        #if DEBUG
        if routes.isEmpty { print("LANGUAGE_PROBE_NO_ROUTE locale=\(candidate.locale)") }
        #endif
        for route in routes {
            guard let transcript = await transcribe(sample, as: candidate, route: route, allowsDownload: allowsDownload) else { continue }
            #if DEBUG
            print("LANGUAGE_PROBE locale=\(candidate.locale) characters=\(transcript.text.count) confidence=\(transcript.confidence)")
            #endif
            return LanguageEvidence.infer(text: transcript.text, speechConfidence: transcript.confidence, requestedLanguage: candidate.code)
        }
        return nil
    }

    private func transcribe(_ sample: URL, as candidate: SpeechLanguageCandidate, route: Route, allowsDownload: Bool) async -> (text: String, confidence: Double)? {
        switch route {
        case .analyzer:
            do {
                guard let transcript = try await SpeechAnalyzerTranscriber.transcribe(
                    file: sample, localeIdentifier: candidate.locale,
                    downloadModelIfNeeded: allowsDownload, timeout: .seconds(12)
                ) else { return nil }
                return (transcript.text, transcript.confidence)
            } catch {
                if !(error is CancellationError) {
                    AppLog.warning("dubbing.language", "Speech analysis for \(candidate.locale) unavailable")
                }
                #if DEBUG
                print("LANGUAGE_PROBE_FAILURE locale=\(candidate.locale) error=\(error)")
                #endif
                return nil
            }
        case .legacy(let recognizer):
            guard let transcript = await LanguageSampleRecognizer().recognize(sample, using: recognizer) else { return nil }
            return (transcript.text, transcript.confidence)
        }
    }

    /// The ways this iPhone can recognize the candidate, best first: the analyzer when its model is
    /// installed, the on-device recognizer, and finally the analyzer with a download when allowed.
    private func routes(for candidate: SpeechLanguageCandidate, allowsDownload: Bool) async -> [Route] {
        let locale = Locale(identifier: candidate.locale)
        var analyzerSupported = false
        var analyzerInstalled = false
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            analyzerSupported = true
            let installed = await SpeechTranscriber.installedLocales
            analyzerInstalled = installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        }
        var result: [Route] = []
        if analyzerInstalled { result.append(.analyzer) }
        if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
            result.append(.legacy(recognizer))
        }
        if allowsDownload, analyzerSupported, !analyzerInstalled { result.append(.analyzer) }
        return result
    }
}

private struct LanguageTranscript { let text: String; let confidence: Double }

/// One on-device recognition of a short sample, cut off at four seconds with whatever was heard so far.
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
