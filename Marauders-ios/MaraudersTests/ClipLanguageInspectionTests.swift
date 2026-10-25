import Foundation
import Testing
@testable import Marauders
@MainActor struct ClipLanguageInspectionTests {
    @Test func englishTextIsOnlyAHintWhenSpeechEvidenceIsStrong() {
        let text = "Welcome to Amsterdam. This beautiful city is famous for canals and bicycles."
        let result = OnDeviceClipLanguageInspector.infer(text: text, speechConfidence: 0.9, requestedLanguage: "en")
        #expect(result?.code == "en")
        #expect(result?.status == "likely")
        #expect(OnDeviceClipLanguageInspector.infer(text: text, speechConfidence: 0.1, requestedLanguage: "en") == nil)
        #expect(OnDeviceClipLanguageInspector.infer(text: text, speechConfidence: 0.9, requestedLanguage: "th") == nil)
        #expect(OnDeviceClipLanguageInspector.infer(text: "Hello", speechConfidence: 0.9, requestedLanguage: "en") == nil)
    }
    @Test func spanishRequiresSpanishEvidenceRatherThanAnExpectedLabel() {
        let text = "Hola, buenos días. Este vídeo contiene una conversación en español sobre nuestra ciudad y sus habitantes."
        let result = OnDeviceClipLanguageInspector.infer(text: text, speechConfidence: 0.9, requestedLanguage: "es")
        #expect(result?.code == "es")
        #expect(OnDeviceClipLanguageInspector.infer(text: text, speechConfidence: 0.9, requestedLanguage: "en") == nil)
        #expect(OnDeviceClipLanguageInspector.infer(text: "Hello, welcome to this beautiful city and its wonderful people.", speechConfidence: 0.9, requestedLanguage: "es") == nil)
    }
    @Test func conflictingLanguagesStayUnknown() {
        let result = OnDeviceClipLanguageInspector.combine([
            .init(status: "likely", code: "en", confidence: 0.9),
            .init(status: "likely", code: "th", confidence: 0.85)
        ])
        #expect(result.status == "unknown")
        #expect(result.code == nil)
        #expect(result.reason == "ambiguous")
        #expect(OnDeviceClipLanguageInspector.combine([]).reason == "not_recognized")
    }
    @Test func legacyAudioAssessmentDecodesWithoutLanguage() throws {
        let json = Data(#"{"content":"speech","speechConfidence":0.9,"musicConfidence":0.1,"signal":"detected","sampledSeconds":3,"exceedsTranslationLimit":false}"#.utf8)
        let old = try JSONDecoder().decode(ClipAudioAssessment.self, from: json)
        #expect(old.spokenLanguage == nil)
        var current = old
        current.spokenLanguage = .init(status: "likely", code: "en", confidence: 0.9)
        #expect(try JSONDecoder().decode(ClipAudioAssessment.self, from: JSONEncoder().encode(current)) == current)
    }
}
