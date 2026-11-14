//
//  DubbingServices+OnDevice.swift
//  Marauders
//

import Foundation

extension DubbingServices {
    /// The real services: Apple's speech engines, the Whisper model and the files they read, all on this iPhone. The
    /// model store and the engine are the shared ones, so the player and the Settings screen follow one download.
    static func onDevice() -> DubbingServices {
        DubbingServices(
            detector: StagedClipLanguageDetector(),
            loader: ClipFileLoader(),
            models: LanguageDetectionModelStore.shared,
            acoustic: WhisperEngine.shared,
            transcriber: WhisperEngine.shared,
            systemSpeech: SystemSpeechTranscriber(),
            voices: SystemNarrationVoices(),
            transcriptLanguage: NaturalLanguageTranscriptChecker(),
            requestSpeechPermission: { await SpeechPermission.request() })
    }
}
