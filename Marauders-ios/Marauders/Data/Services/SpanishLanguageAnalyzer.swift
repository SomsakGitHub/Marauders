import AVFoundation
import Foundation
import Speech

/// Spanish speech is processed locally by the newer analyzer. Only model assets
/// are downloaded from Apple; audio and transcript text remain on the device.
@MainActor enum SpanishLanguageAnalyzer {
    static func infer(sample: URL, downloadModelIfNeeded: Bool = true) async throws -> SpokenLanguageAssessment? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es-ES")) else { return nil }
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
                AppLog.info("upload.language", "Preparing Spanish speech model on device")
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
            return (text, confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count))
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        defer { watchdog.cancel() }
        do {
            let evidence = try await withTaskCancellationHandler {
                let file = try AVAudioFile(forReading: sample)
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await results.value
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            #if DEBUG
            print("SPANISH_ANALYSIS characters=\(evidence.0.count) confidence=\(evidence.1)")
            #endif
            guard var assessment = OnDeviceClipLanguageInspector.infer(text: evidence.0, speechConfidence: evidence.1,
                                                                      requestedLanguage: "es") else { return nil }
            assessment.method = "on_device_speech_analyzer_text"
            return assessment
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }
}
