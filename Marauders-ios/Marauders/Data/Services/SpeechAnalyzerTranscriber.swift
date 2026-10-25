import AVFoundation
import Foundation
import Speech

struct SpeechTranscript: Sendable {
    let text: String
    let confidence: Double
}

/// Transcribes a short audio file with the iOS 26 `SpeechAnalyzer`, entirely on device.
/// Only Apple-managed model assets are ever downloaded; audio and text never leave the phone.
@MainActor enum SpeechAnalyzerTranscriber {
    /// Returns nil when the locale is unsupported, or the model is missing and downloading is not allowed.
    static func transcribe(file: URL, localeIdentifier: String, downloadModelIfNeeded: Bool,
                           timeout: Duration) async throws -> SpeechTranscript? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.transcriptionConfidence])
        let installed = await AssetInventory.status(forModules: [transcriber]) == .installed
        guard installed || downloadModelIfNeeded else { return nil }
        if !installed {
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(locale) {
                guard try await AssetInventory.reserve(locale: locale) else { return nil }
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                AppLog.info("speech.model", "Preparing \(localeIdentifier) speech model on device")
                try await request.downloadAndInstall()
            }
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            var text = ""
            var confidences: [Double] = []
            for try await result in transcriber.results {
                text += String(result.text.characters) + " "
                for run in result.text.runs {
                    if let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                        confidences.append(confidence)
                    }
                }
            }
            return SpeechTranscript(text: text, confidence: confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count))
        }
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        defer { watchdog.cancel() }
        do {
            let transcript = try await withTaskCancellationHandler {
                let audio = try AVAudioFile(forReading: file)
                _ = try await analyzer.analyzeSequence(from: audio)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await results.value
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            return transcript
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }
}
