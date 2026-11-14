//
//  DubbingServices.swift
//  Marauders
//

import Foundation

/// What `DubbingViewModel` needs from this iPhone to find a clip's language, write its speech down and read the
/// translation aloud. Every one is a Domain protocol: the real ones are Data types that `AppDependencyContainer`
/// puts together (`DubbingServices.onDevice()`), so nothing in Presentation names them.
struct DubbingServices {
    /// Names a clip's language with Apple's recognizers, which only know a few languages.
    var detector: any ClipLanguageDetecting
    /// Brings a clip to a local file the audio can be read from.
    var loader: any ClipFileLoading
    /// The Whisper model on this iPhone: whether it is there, and its download.
    var models: any LanguageDetectionModelManaging
    /// Names a clip's language by listening to it, with the Whisper model.
    var acoustic: any AcousticLanguageIdentifying
    /// Writes a clip's speech down with the Whisper model (Dutch).
    var transcriber: any AcousticTranscribing
    /// Writes a clip's speech down with Apple's speech engine (Spanish, and English without the legacy recognizer).
    var systemSpeech: any SystemSpeechTranscribing
    /// Picks the voice that reads the translation aloud.
    var voices: any NarrationVoiceChoosing
    /// Checks that what the Whisper model wrote reads as the clip's language before it is translated.
    var transcriptLanguage: any TranscriptLanguageChecking
    /// Asks for speech recognition once; true when the viewer has allowed it.
    var requestSpeechPermission: () async -> Bool
}

extension DubbingServices {
    /// Services that can do nothing: no model is installed, nothing is heard, no voice is found and nothing can be
    /// downloaded, so a view model built on them ends in the "unavailable" messages instead of reaching an engine. It
    /// is what a Release build gives a clip player that no one installed a factory for (a Debug build stops), and what
    /// tests start from.
    static var unavailable: DubbingServices {
        DubbingServices(
            detector: NoClipLanguageDetector(),
            loader: NoClipFileLoader(),
            models: NoLanguageDetectionModel(),
            acoustic: NoopAcousticLanguageIdentifier(),
            transcriber: NoAcousticTranscriber(),
            systemSpeech: NoSystemSpeech(),
            voices: NoNarrationVoices(),
            transcriptLanguage: NoTranscriptLanguageCheck(),
            requestSpeechPermission: { false })
    }
}

private struct NoClipLanguageDetector: ClipLanguageDetecting {
    func detect(sample: URL, among candidates: [SpeechLanguageCandidate]) async -> SpeechLanguageDetection? { nil }
}

private struct NoClipFileLoader: ClipFileLoading {
    func load(_ url: URL, into folder: URL, check: () throws -> Void) async throws -> URL {
        throw DubbingError.unavailable
    }
}

private nonisolated struct NoLanguageDetectionModel: LanguageDetectionModelManaging {
    func isInstalled() async -> Bool { false }
    func status() async -> LanguageModelStatus { .notInstalled }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws { throw DubbingError.unavailable }
    func remove() async {}
}

private nonisolated struct NoAcousticTranscriber: AcousticTranscribing {
    func transcribe(file: URL, languageCode: String) async throws -> AcousticTranscript? { nil }
}

private struct NoSystemSpeech: SystemSpeechTranscribing {
    func transcribe(file: URL, localeIdentifier: String, downloadModelIfNeeded: Bool, timeout: Duration)
        async throws -> SpeechTranscript?
    { nil }
}

private struct NoNarrationVoices: NarrationVoiceChoosing {
    func voiceLanguageTag(for language: ListeningLanguage) -> String? { nil }
}

private struct NoTranscriptLanguageCheck: TranscriptLanguageChecking {
    func isPlausible(text: String, confidence: Double, languageCode: String) -> Bool { false }
}
