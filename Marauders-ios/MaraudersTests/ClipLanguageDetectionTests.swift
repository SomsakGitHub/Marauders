import Foundation
import Testing
@testable import Marauders

@MainActor struct ClipLanguageDetectionTests {
    @Test func englishTextIsOnlyAHintWhenSpeechEvidenceIsStrong() {
        let text = "Welcome to Amsterdam. This beautiful city is famous for canals and bicycles."
        let result = LanguageEvidence.infer(text: text, speechConfidence: 0.9, requestedLanguage: "en")
        #expect(result?.code == "en")
        #expect((result?.confidence ?? 0) >= 0.8)
        #expect(LanguageEvidence.infer(text: text, speechConfidence: 0.1, requestedLanguage: "en") == nil)
        #expect(LanguageEvidence.infer(text: text, speechConfidence: 0.9, requestedLanguage: "th") == nil)
        #expect(LanguageEvidence.infer(text: "Hello", speechConfidence: 0.9, requestedLanguage: "en") == nil)
    }

    @Test func spanishRequiresSpanishEvidenceRatherThanAnExpectedLabel() {
        let text = "Hola, buenos días. Este vídeo contiene una conversación en español sobre nuestra ciudad y sus habitantes."
        let result = LanguageEvidence.infer(text: text, speechConfidence: 0.9, requestedLanguage: "es")
        #expect(result?.code == "es")
        #expect(LanguageEvidence.infer(text: text, speechConfidence: 0.9, requestedLanguage: "en") == nil)
        #expect(LanguageEvidence.infer(text: "Hello, welcome to this beautiful city and its wonderful people.", speechConfidence: 0.9, requestedLanguage: "es") == nil)
    }

    @Test func confidenceIsTheWeakerOfTheRecognizerAndTheTextCheck() {
        let text = "Welcome to Amsterdam. This beautiful city is famous for canals and bicycles."
        let result = LanguageEvidence.infer(text: text, speechConfidence: 0.6, requestedLanguage: "en")
        #expect(result?.confidence == 0.6)
    }

    @Test func conflictingLanguagesStayUndecided() {
        let en = SpeechLanguageDetection(code: "en", confidence: 0.9)
        let th = SpeechLanguageDetection(code: "th", confidence: 0.85)
        #expect(StagedClipLanguageDetector.decide([en, th]) == nil)
        #expect(StagedClipLanguageDetector.decide([en, .init(code: "th", confidence: 0.7)]) == en)
        #expect(StagedClipLanguageDetector.decide([en, .init(code: "en", confidence: 0.88)]) == en)
        #expect(StagedClipLanguageDetector.decide([]) == nil)
    }

    @Test func aLanguageWeCannotDubFromNeedsStrongEvidenceOnItsOwn() {
        // German text read out of a Dutch clip scored 0.51: believable, and wrong.
        #expect(StagedClipLanguageDetector.decide([.init(code: "de", confidence: 0.51)]) == nil)
        #expect(StagedClipLanguageDetector.decide([.init(code: "de", confidence: 0.64)]) == nil)
        #expect(StagedClipLanguageDetector.decide([.init(code: "de", confidence: 0.65)])?.code == "de")
        #expect(StagedClipLanguageDetector.decide([.init(code: "th", confidence: 0.8)])?.code == "th")
        // A language we can dub from is useful even at modest confidence.
        #expect(StagedClipLanguageDetector.decide([.init(code: "es", confidence: 0.55)])?.code == "es")
        // Stronger evidence for a dubbing source still beats a weak own-language reading.
        #expect(StagedClipLanguageDetector.decide([.init(code: "en", confidence: 0.9), .init(code: "de", confidence: 0.5)])?.code == "en")
    }

    @Test func aWhisperTranscriptMustReadAsTheLanguageItWasToldToUse() {
        let dutch = "Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten en twee komkommers alstublieft."
        #expect(LanguageEvidence.transcriptIsPlausible(text: dutch, confidence: 0.65, languageCode: "nl"))
        // The same words are not plausible as German, or when the engine was barely sure.
        #expect(!LanguageEvidence.transcriptIsPlausible(text: "Guten Morgen, ich hätte gern ein Kilo Tomaten und ein paar Karotten, bitte.", confidence: 0.65, languageCode: "nl"))
        #expect(!LanguageEvidence.transcriptIsPlausible(text: dutch, confidence: 0.3, languageCode: "nl"))
        #expect(LanguageEvidence.transcriptIsPlausible(text: dutch, confidence: 0.4, languageCode: "nl"))
    }

    @Test func aVeryShortTranscriptIsJudgedOnConfidenceAlone() {
        #expect(LanguageEvidence.transcriptIsPlausible(text: "Dank je wel", confidence: 0.6, languageCode: "nl"))
        #expect(!LanguageEvidence.transcriptIsPlausible(text: "Dank je wel", confidence: 0.2, languageCode: "nl"))
        #expect(!LanguageEvidence.transcriptIsPlausible(text: "Ja", confidence: 0.9, languageCode: "nl"))
        #expect(!LanguageEvidence.transcriptIsPlausible(text: "", confidence: 0.9, languageCode: "nl"))
    }

    @Test func legacyAudioAssessmentDecodesWithoutLanguage() throws {
        let json = Data(#"{"content":"speech","speechConfidence":0.9,"musicConfidence":0.1,"signal":"detected","sampledSeconds":3,"exceedsTranslationLimit":false}"#.utf8)
        let old = try JSONDecoder().decode(ClipAudioAssessment.self, from: json)
        #expect(old.spokenLanguage == nil)
        var current = old
        current.spokenLanguage = .init(status: "likely", code: "en", confidence: 0.9)
        #expect(try JSONDecoder().decode(ClipAudioAssessment.self, from: JSONEncoder().encode(current)) == current)
    }

    // MARK: Staging

    private final class FakeEvidence: SpeechEvidenceProviding {
        var installedCodes: Set<String>
        var results: [String: SpeechLanguageDetection]
        private(set) var calls: [String] = []
        init(installed: Set<String>, results: [String: SpeechLanguageDetection]) {
            installedCodes = installed
            self.results = results
        }
        func installed(_ candidates: [SpeechLanguageCandidate]) async -> [SpeechLanguageCandidate] {
            candidates.filter { installedCodes.contains($0.code) }
        }
        func evidence(for candidate: SpeechLanguageCandidate, sample: URL, allowsDownload: Bool) async -> SpeechLanguageDetection? {
            calls.append("\(candidate.code):\(allowsDownload ? "download" : "installed")")
            return results[candidate.code]
        }
    }

    private let sample = URL(fileURLWithPath: "/tmp/sample.wav")
    private let english = SpeechLanguageCandidate(code: "en", locale: "en-US")
    private let spanish = SpeechLanguageCandidate(code: "es", locale: "es-ES")

    @Test func aConfidentInstalledLanguageEndsTheSearchWithoutDownloadingAnything() async {
        let provider = FakeEvidence(installed: ["en"], results: ["en": .init(code: "en", confidence: 0.9)])
        let result = await StagedClipLanguageDetector(provider: provider).detect(sample: sample, among: [english, spanish])
        #expect(result == .init(code: "en", confidence: 0.9))
        #expect(provider.calls == ["en:installed"])
    }

    @Test func anUnsureInstalledResultLetsOtherLanguagesDownloadAndWin() async {
        let provider = FakeEvidence(installed: ["en"], results: [
            "en": .init(code: "en", confidence: 0.6),
            "es": .init(code: "es", confidence: 0.9)
        ])
        let result = await StagedClipLanguageDetector(provider: provider).detect(sample: sample, among: [english, spanish])
        #expect(result == .init(code: "es", confidence: 0.9))
        #expect(provider.calls == ["en:installed", "es:download"])
    }

    @Test func downloadingStaysAvailableWhenNothingIsInstalled() async {
        let provider = FakeEvidence(installed: [], results: ["es": .init(code: "es", confidence: 0.85)])
        let result = await StagedClipLanguageDetector(provider: provider).detect(sample: sample, among: [english, spanish])
        #expect(result?.code == "es")
        #expect(provider.calls == ["en:download", "es:download"])
    }

    @Test func closeCompetitorsAreAmbiguousEvenWhenBothAreInstalled() async {
        let provider = FakeEvidence(installed: ["en", "es"], results: [
            "en": .init(code: "en", confidence: 0.82),
            "es": .init(code: "es", confidence: 0.8)
        ])
        #expect(await StagedClipLanguageDetector(provider: provider).detect(sample: sample, among: [english, spanish]) == nil)
    }

    @Test func nothingRecognizedAndNoCandidatesBothGiveNoAnswer() async {
        let provider = FakeEvidence(installed: ["en", "es"], results: [:])
        let detector = StagedClipLanguageDetector(provider: provider)
        #expect(await detector.detect(sample: sample, among: [english, spanish]) == nil)
        #expect(await detector.detect(sample: sample, among: []) == nil)
    }

    @Test func recognizableLanguagesHaveAConventionalLocale() {
        #expect(SpeechLanguageCandidate.recognizable("th")?.locale == "th-TH")
        #expect(SpeechLanguageCandidate.recognizable("es") == spanish)
        #expect(SpeechLanguageCandidate.recognizable("da") == nil)
        for source in DubbingSourceLanguage.allCases where source.isRecognizedWithoutDetectionModel {
            #expect(SpeechLanguageCandidate.recognizable(source.translationCode) == source.candidate)
        }
        // Dutch is found by the detection model, not by the quick recognizers.
        #expect(SpeechLanguageCandidate.recognizable("nl") == nil)
        #expect(DubbingSourceLanguage.recognizerCandidates.map(\.code) == ["en", "es"])
    }
}
