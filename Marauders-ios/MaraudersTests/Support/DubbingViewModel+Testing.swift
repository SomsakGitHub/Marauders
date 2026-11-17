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

    /// The production initializer with the three shared stores left out: each is one of the test's own, in a suite of
    /// its own, so no test sees what another remembered.
    convenience init(
        cache: any DubbedAudioCaching, services: DubbingServices,
        reports: DubbedAudioReportMemory? = nil, memo: DetectedLanguageMemo? = nil,
        consent: LanguageDetectionConsent? = nil
    ) {
        self.init(
            cache: cache, services: services,
            reports: reports ?? DubbedAudioReportMemory(defaults: Self.isolatedDefaults()),
            memo: memo ?? DetectedLanguageMemo(defaults: Self.isolatedDefaults()),
            consent: consent ?? LanguageDetectionConsent())
    }

    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
    }
}
