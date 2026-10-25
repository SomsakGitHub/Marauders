import Foundation

/// Spanish speech is processed locally by the newer analyzer. Only model assets
/// are downloaded from Apple; audio and transcript text remain on the device.
@MainActor enum SpanishLanguageAnalyzer {
    static func infer(sample: URL, downloadModelIfNeeded: Bool = true) async throws -> SpokenLanguageAssessment? {
        guard let evidence = try await SpeechAnalyzerTranscriber.transcribe(
            file: sample, localeIdentifier: "es-ES", downloadModelIfNeeded: downloadModelIfNeeded, timeout: .seconds(12)
        ) else { return nil }
        #if DEBUG
        print("SPANISH_ANALYSIS characters=\(evidence.text.count) confidence=\(evidence.confidence)")
        #endif
        guard var assessment = OnDeviceClipLanguageInspector.infer(text: evidence.text, speechConfidence: evidence.confidence,
                                                                  requestedLanguage: "es") else { return nil }
        assessment.method = "on_device_speech_analyzer_text"
        return assessment
    }
}
