//
//  DubbingViewModel+Testing.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

extension DubbingViewModel {
    /// The shape the dubbing tests were written against: every collaborator is optional, and one a test leaves out is
    /// the inert one from `DubbingServices.unavailable`, so no test reaches this iPhone's speech engines, its model
    /// folder or the network by accident. The one exception is the check that a transcript reads as its language: it is
    /// the real one, because it is a pure function and the tests about what the Whisper model writes depend on it.
    convenience init(
        cache: any DubbedAudioCaching,
        reports: DubbedAudioReportMemory? = nil,
        detector: (any ClipLanguageDetecting)? = nil,
        loader: (any ClipFileLoading)? = nil,
        memo: DetectedLanguageMemo? = nil,
        models: (any LanguageDetectionModelManaging)? = nil,
        acoustic: (any AcousticLanguageIdentifying)? = nil,
        transcriber: (any AcousticTranscribing)? = nil,
        consent: LanguageDetectionConsent? = nil,
        requestSpeechPermission: (() async -> Bool)? = nil
    ) {
        var services = DubbingServices.unavailable
        services.transcriptLanguage = NaturalLanguageTranscriptChecker()
        if let detector { services.detector = detector }
        if let loader { services.loader = loader }
        if let models { services.models = models }
        if let acoustic { services.acoustic = acoustic }
        if let transcriber { services.transcriber = transcriber }
        if let requestSpeechPermission { services.requestSpeechPermission = requestSpeechPermission }
        self.init(cache: cache, services: services, reports: reports, memo: memo, consent: consent)
    }
}
