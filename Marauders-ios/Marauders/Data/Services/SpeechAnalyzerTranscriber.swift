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
        // Assets can be on the iPhone for the system (for example through Dictation) without this app
        // having claimed them, so "installed" also looks at the system's installed locales.
        let status = await AssetInventory.status(forModules: [transcriber])
        var present = status == .installed
        if !present {
            let installedLocales = await SpeechTranscriber.installedLocales
            present = installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard present || downloadModelIfNeeded else { return nil }
        // Using a locale requires reserving it for this app; reserving assets already on the iPhone downloads nothing.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            guard try await AssetInventory.reserve(locale: locale) else { return nil }
        }
        if !present, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            AppLog.info("speech.model", "Preparing \(localeIdentifier) speech model on device")
            try await request.downloadAndInstall()
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
