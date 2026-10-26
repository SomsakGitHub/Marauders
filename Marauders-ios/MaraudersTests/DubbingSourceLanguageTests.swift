import Foundation
import Testing
@testable import Marauders

@MainActor
struct DubbingSourceLanguageTests {
    private func clip(_ language: SpokenLanguageAssessment?) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!,
                  audioAssessment: ClipAudioAssessment(content: .speech, signal: .detected, spokenLanguage: language))
    }

    @Test func codesMapToSupportedSourcesIgnoringRegionAndCase() {
        #expect(DubbingSourceLanguage(code: "es") == .spanish)
        #expect(DubbingSourceLanguage(code: "es-MX") == .spanish)
        #expect(DubbingSourceLanguage(code: "EN-us") == .english)
        #expect(DubbingSourceLanguage(code: "fr") == nil)
        #expect(DubbingSourceLanguage(code: "") == nil)
    }

    @Test func aClipDeclaresItsLanguageOnlyWhenSomeoneSaidSo() {
        #expect(clip(.chosen("es")).declaredSourceCode == "es")
        #expect(clip(.chosen("es")).dubbingSourceLanguage == .spanish)
        #expect(clip(.init(status: "likely", code: "es-MX", confidence: 0.8)).declaredSourceCode == "es")
        #expect(clip(.init(status: "likely", code: "es-MX", confidence: 0.8)).dubbingSourceLanguage == .spanish)
        #expect(clip(.chosen("en")).dubbingSourceLanguage == .english)
    }

    @Test func unknownOrMissingLanguagesAreNotGuessed() {
        #expect(clip(.unknown("ambiguous")).declaredSourceCode == nil)
        #expect(clip(.unknown("ambiguous")).dubbingSourceLanguage == nil)
        #expect(clip(nil).dubbingSourceLanguage == nil)
        #expect(FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!).declaredSourceCode == nil)
        // A code without a confident status is never trusted.
        #expect(clip(.init(status: "unknown", code: "es")).declaredSourceCode == nil)
    }

    @Test func aDeclaredLanguageWeCannotDubFromIsStillReported() {
        #expect(clip(.chosen("fr")).declaredSourceCode == "fr")
        #expect(clip(.chosen("fr")).dubbingSourceLanguage == nil)
    }

    @Test func dutchIsADubbingSourceThatUsesTheWhisperModel() {
        #expect(DubbingSourceLanguage(code: "nl") == .dutch)
        #expect(DubbingSourceLanguage(code: "nl-BE") == .dutch)
        #expect(DubbingSourceLanguage.dutch.translationCode == "nl")
        #expect(DubbingSourceLanguage.dutch.speechLocale == "nl-NL")
        #expect(DubbingSourceLanguage.dutch.speechEngine == .whisper)
        #expect(DubbingSourceLanguage.spanish.speechEngine == .speechTranscriber)
        #expect(DubbingSourceLanguage.english.speechEngine == .recognizer)
        #expect(clip(.chosen("nl")).dubbingSourceLanguage == .dutch)
    }

    @Test func languageCodesMatchAppleFrameworks() {
        #expect(DubbingSourceLanguage.spanish.translationCode == "es")
        #expect(DubbingSourceLanguage.spanish.speechLocale == "es-ES")
        #expect(DubbingSourceLanguage.english.speechLocale == "en-US")
        #expect(DubbingSourceLanguage.spanish.candidate == SpeechLanguageCandidate(code: "es", locale: "es-ES"))
    }
}
