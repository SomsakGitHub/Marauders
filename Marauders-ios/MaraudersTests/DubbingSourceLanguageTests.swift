import Foundation
import Testing
@testable import Marauders

@MainActor
struct DubbingSourceLanguageTests {
    private func clip(_ language: SpokenLanguageAssessment?) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!,
                  audioAssessment: ClipAudioAssessment(content: .speech, signal: .detected, spokenLanguage: language))
    }

    @Test func likelySpanishSelectsSpanish() {
        let spanish = SpokenLanguageAssessment(status: "likely", code: "es", confidence: 0.89)
        #expect(clip(spanish).dubbingSourceLanguage == .spanish)
        #expect(DubbingSourceLanguage(spokenLanguage: .init(status: "likely", code: "es-MX", confidence: 0.8)) == .spanish)
    }

    @Test func englishUnknownOrMissingKeepsEnglish() {
        #expect(clip(.init(status: "likely", code: "en", confidence: 0.9)).dubbingSourceLanguage == .english)
        #expect(clip(.unknown("ambiguous")).dubbingSourceLanguage == .english)
        #expect(clip(nil).dubbingSourceLanguage == .english)
        #expect(FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!).dubbingSourceLanguage == .english)
    }

    @Test func unknownStatusNeverSelectsSpanishEvenWithACode() {
        #expect(DubbingSourceLanguage(spokenLanguage: .init(status: "unknown", code: "es")) == .english)
    }

    @Test func uploaderChosenSpanishSelectsSpanishAndAnUnsureChoiceDoesNot() {
        #expect(clip(.chosen("es")).dubbingSourceLanguage == .spanish)
        #expect(clip(.chosen("en")).dubbingSourceLanguage == .english)
        #expect(clip(.unsure()).dubbingSourceLanguage == .english)
    }

    @Test func languageCodesMatchAppleFrameworks() {
        #expect(DubbingSourceLanguage.spanish.translationCode == "es")
        #expect(DubbingSourceLanguage.spanish.speechLocale == "es-ES")
        #expect(DubbingSourceLanguage.english.speechLocale == "en-US")
    }
}
