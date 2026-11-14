//
//  DubbingSpeechSeamsTests.swift
//  MaraudersTests
//

import AVFoundation
import Foundation
import Testing

@testable import Marauders

/// The seams `DubbingViewModel` reaches this iPhone's speech machinery through, in place of naming Apple's engines
/// and the NaturalLanguage check itself, and the real services the composition root puts behind them.
@MainActor
struct DubbingSpeechSeamsTests {
    /// Answers one scripted outcome per call and remembers what it was asked.
    private final class FakeSystemSpeech: SystemSpeechTranscribing {
        enum Outcome {
            case transcript(String, confidence: Double)
            case missingModel
            case failure(Error)
        }

        struct Request: Equatable {
            let file: String
            let locale: String
            let downloadsModel: Bool
            let timeout: Duration
        }

        private var outcomes: [Outcome]
        private(set) var requests: [Request] = []
        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func transcribe(file: URL, localeIdentifier: String, downloadModelIfNeeded: Bool, timeout: Duration)
            async throws -> SpeechTranscript?
        {
            requests.append(
                Request(
                    file: file.lastPathComponent, locale: localeIdentifier, downloadsModel: downloadModelIfNeeded,
                    timeout: timeout))
            switch outcomes.removeFirst() {
            case .transcript(let text, let confidence): return SpeechTranscript(text: text, confidence: confidence)
            case .missingModel: return nil
            case .failure(let error): throw error
            }
        }
    }

    /// Says what it was told to about every transcript and remembers what it was asked.
    private final class FakePlausibility: TranscriptLanguageChecking {
        struct Question { let text: String; let confidence: Double; let languageCode: String }
        let answer: Bool
        private(set) var questions: [Question] = []
        init(_ answer: Bool) { self.answer = answer }

        func isPlausible(text: String, confidence: Double, languageCode: String) -> Bool {
            questions.append(Question(text: text, confidence: confidence, languageCode: languageCode))
            return answer
        }
    }

    private final class FakeVoices: NarrationVoiceChoosing {
        let tag: String?
        private(set) var asked: [ListeningLanguage] = []
        init(_ tag: String?) { self.tag = tag }

        func voiceLanguageTag(for language: ListeningLanguage) -> String? {
            asked.append(language)
            return tag
        }
    }

    private func makeModel(
        transcriber: (any AcousticTranscribing)? = nil,
        systemSpeech: (any SystemSpeechTranscribing)? = nil,
        transcriptLanguage: (any TranscriptLanguageChecking)? = nil,
        voices: (any NarrationVoiceChoosing)? = nil
    ) -> DubbingViewModel {
        var services = DubbingServices.unavailable
        if let transcriber { services.transcriber = transcriber }
        if let systemSpeech { services.systemSpeech = systemSpeech }
        if let transcriptLanguage { services.transcriptLanguage = transcriptLanguage }
        if let voices { services.voices = voices }
        return DubbingViewModel(cache: NoDubbedAudioCache(), services: services)
    }

    /// Runs `transcribeClip` on a Spanish tone clip of `seconds`, which Apple's engine reads in 20-second windows.
    private func transcribeSpanish(with speech: FakeSystemSpeech, seconds: Double = 2) async throws -> Result<
        String, Error
    > {
        let clip = try TestFixtureFiles.temporaryToneFile(seconds: seconds)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: clip)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = makeModel(systemSpeech: speech)
        do {
            let text = try await model.transcribeClip(
                at: clip, in: folder, language: .spanish, speech: nil, current: model.generation)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    /// Runs `transcribeClip` on a Dutch clip whose Whisper transcript is `text`, with `checker` judging the language.
    private func transcribeDutch(_ text: String, confidence: Double, checker: FakePlausibility) async -> Result<
        String, Error
    > {
        let transcriber = DubbingPlanTests.makeTranscriber(
            .transcript(AcousticTranscript(text: text, confidence: confidence)))
        let model = makeModel(transcriber: transcriber, transcriptLanguage: checker)
        do {
            let text = try await model.transcribeClip(
                at: URL(fileURLWithPath: "/tmp/clip.mp4"), in: URL(fileURLWithPath: "/tmp"), language: .dutch,
                speech: nil, current: model.generation)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Apple's speech engine

    @Test func spanishGoesToTheSystemTranscriberInTwentySecondWindowsAndMayDownloadItsModel() async throws {
        let speech = FakeSystemSpeech([
            .transcript("Hola a todos", confidence: 0.9), .transcript("buenas tardes", confidence: 0.8),
        ])
        let result = try await transcribeSpanish(with: speech, seconds: 25)
        #expect(try result.get() == "Hola a todos buenas tardes")
        #expect(speech.requests.map(\.file) == ["speech-0.wav", "speech-1.wav"])
        #expect(speech.requests.allSatisfy { $0.locale == "es-ES" && $0.downloadsModel && $0.timeout == .seconds(60) })
    }

    @Test func whatTheSystemTranscriberReportsBecomesTheMatchingDubbingError() async throws {
        let spanish = DubbingSourceLanguage.spanish.displayName()
        let cases: [(FakeSystemSpeech.Outcome, DubbingError)] = [
            (.missingModel, .unavailable),
            (.failure(SpeechModelInstallError.limitReached), .speechModelLimit),
            (.failure(SpeechModelInstallError.downloadFailed), .speechModelDownloadFailed(language: spanish)),
            (.failure(URLError(.unknown)), .speechUnclear),
        ]
        for (outcome, expected) in cases {
            let result = try await transcribeSpanish(with: FakeSystemSpeech([outcome]))
            guard case .failure(let error) = result else {
                Issue.record("Expected \(expected) to be thrown")
                continue
            }
            #expect((error as? DubbingError)?.errorDescription == expected.errorDescription)
        }
    }

    @Test func aCancelledTranscriptionStaysACancellation() async throws {
        let result = try await transcribeSpanish(with: FakeSystemSpeech([.failure(CancellationError())]))
        guard case .failure(let error) = result else {
            Issue.record("Expected the cancellation to be thrown")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: The Whisper model's text

    @Test func theWhisperTextIsKeptOnlyWhenTheLanguageCheckAcceptsIt() async throws {
        let dutch = "Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten."
        let refusing = FakePlausibility(false)
        let refused = await transcribeDutch(dutch, confidence: 0.7, checker: refusing)
        guard case .failure(let error) = refused else {
            Issue.record("A transcript the check refuses must not be translated")
            return
        }
        #expect((error as? DubbingError)?.errorDescription == DubbingError.speechUnclear.errorDescription)
        // It was asked about the whole text, the model's own confidence and the clip's language.
        let question = try #require(refusing.questions.first)
        #expect(question.text == dutch)
        #expect(abs(question.confidence - 0.7) < 0.000_001)
        #expect(question.languageCode == "nl")

        // The check decides, not the words: text it accepts goes on to be translated.
        let accepting = FakePlausibility(true)
        let english = "Not Dutch at all, but the check says so."
        let accepted = await transcribeDutch(english, confidence: 0.7, checker: accepting)
        #expect(try accepted.get() == english)
    }

    // MARK: The voice

    @Test func theNarrationVoiceIsTheSystemsDefaultForTheChosenLanguageTag() {
        let voices = FakeVoices("en-US")
        let model = makeModel(voices: voices)
        #expect(model.narrationVoice(for: .english)?.language == "en-US")
        #expect(voices.asked == [.english])
    }

    @Test func noInstalledVoiceMeansNoNarrationVoice() {
        #expect(makeModel(voices: FakeVoices(nil)).narrationVoice(for: .thai) == nil)
        #expect(makeModel(voices: FakeVoices("zz-ZZ")).narrationVoice(for: .thai) == nil)
    }

    // MARK: Services

    @Test func servicesThatAreNotAvailableAnswerNoToEverything() async throws {
        let services = DubbingServices.unavailable
        let file = URL(fileURLWithPath: "/tmp/sample.wav")
        #expect(await services.detector.detect(sample: file, among: DubbingSourceLanguage.recognizerCandidates) == nil)
        await #expect(throws: DubbingError.self) { _ = try await services.loader.load(file, into: file, check: {}) }
        #expect(await !services.models.isInstalled())
        #expect(await services.models.status() == .notInstalled)
        await #expect(throws: DubbingError.self) { try await services.models.install { _ in } }
        #expect(await services.acoustic.identify(window: file) == nil)
        #expect(try await services.transcriber.transcribe(file: file, languageCode: "nl") == nil)
        #expect(
            try await services.systemSpeech.transcribe(
                file: file, localeIdentifier: "es-ES", downloadModelIfNeeded: true, timeout: .seconds(1)) == nil)
        #expect(services.voices.voiceLanguageTag(for: .english) == nil)
        let greeting = "Hello there, nice to meet you"
        #expect(!services.transcriptLanguage.isPlausible(text: greeting, confidence: 1, languageCode: "en"))
        #expect(await !services.requestSpeechPermission())
    }

    @Test func theOnDeviceServicesAreTheRealOnesAndShareTheModelsWithSettings() {
        let services = DubbingServices.onDevice()
        // The player and the Settings screen follow one download, so they must talk to the same store.
        #expect((services.models as? LanguageDetectionModelStore) === LanguageDetectionModelStore.shared)
        #expect((services.acoustic as? WhisperEngine) === WhisperEngine.shared)
        #expect((services.transcriber as? WhisperEngine) === WhisperEngine.shared)
        #expect(services.detector is StagedClipLanguageDetector)
        #expect(services.loader is ClipFileLoader)
        #expect(services.systemSpeech is SystemSpeechTranscriber)
        #expect(services.voices is SystemNarrationVoices)
        #expect(services.transcriptLanguage is NaturalLanguageTranscriptChecker)
    }

    // MARK: The real services behind the seams

    @Test func theLanguageCheckAppliesTheLanguageEvidenceRules() {
        let checker = NaturalLanguageTranscriptChecker()
        let dutch = "Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten."
        let english = "Good morning, can I help you? I would like a kilo of tomatoes and two cucumbers please."
        #expect(checker.isPlausible(text: dutch, confidence: 0.65, languageCode: "nl"))
        #expect(!checker.isPlausible(text: dutch, confidence: 0.3, languageCode: "nl"))
        #expect(!checker.isPlausible(text: english, confidence: 0.8, languageCode: "nl"))
        #expect(checker.isPlausible(text: "Dank je wel", confidence: 0.6, languageCode: "nl"))
    }

    @Test func theNarrationVoicesAreTheCatalogsBestInstalledOnes() {
        let voices = SystemNarrationVoices()
        let installed = SpeechVoiceCatalog.candidates()
        for language in [ListeningLanguage.english, .thai] {
            #expect(
                voices.voiceLanguageTag(for: language)
                    == SpeechVoiceCatalog.bestLanguageTag(for: language, among: installed))
        }
        // Every iPhone has an English voice, so this also shows the adapter finds installed voices at all.
        #expect(voices.voiceLanguageTag(for: .english) != nil)
    }

    @Test func theSystemTranscriberHasNothingForALocaleNoEngineSupports() async throws {
        let nothing = try await SystemSpeechTranscriber().transcribe(
            file: URL(fileURLWithPath: "/tmp/none.wav"), localeIdentifier: "xx-XX", downloadModelIfNeeded: false,
            timeout: .seconds(1))
        #expect(nothing == nil)
    }
}
