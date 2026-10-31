//
//  CommentTranslationTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct CommentTranslationTests {
    private let english = ListeningLanguage(identifier: "en")
    private let thai = ListeningLanguage(identifier: "th")

    @Test func aDeclaredLanguageDifferentFromTheViewersIsOffered() {
        let comment = Comment(body: "hola", language: "es")
        #expect(CommentTranslation.source(for: comment, target: english) == .known("es"))
    }

    @Test func aDeclaredLanguageThatIsTheViewersIsNotOffered() {
        let comment = Comment(body: "hello", language: "en-GB")
        #expect(CommentTranslation.source(for: comment, target: english) == nil)
    }

    @Test func aDeclaredLanguageWeCannotTranslateIsNotOffered() {
        let comment = Comment(body: "Ceci n'est pas un test", language: "xx")
        // Falls back to detection, which finds French.
        #expect(CommentTranslation.source(for: comment, target: english) == .known("fr"))
        let unknown = Comment(body: "short", language: "xx")
        #expect(CommentTranslation.source(for: unknown, target: english) == nil)
    }

    @Test func aViewerWithoutAListeningLanguageIsOfferedNothing() {
        let comment = Comment(body: "hola", language: "es")
        #expect(CommentTranslation.source(for: comment, target: nil) == nil)
    }

    @Test func anUndeclaredLanguageIsDetectedOnTheIPhone() {
        let spanish = Comment(body: "Este lugar es increíble, volveremos pronto")
        #expect(CommentTranslation.source(for: spanish, target: english) == .known("es"))
        let thaiText = Comment(body: "ที่นี่สวยมาก อยากกลับไปอีกครั้ง")
        #expect(CommentTranslation.source(for: thaiText, target: english) == .known("th"))
    }

    @Test func detectedTextInTheViewersLanguageIsNotOffered() {
        let comment = Comment(body: "This place is incredible, we will be back soon")
        #expect(CommentTranslation.source(for: comment, target: english) == nil)
        let thaiText = Comment(body: "ที่นี่สวยมาก อยากกลับไปอีกครั้ง")
        #expect(CommentTranslation.source(for: thaiText, target: thai) == nil)
    }

    @Test func aShortCommentInAnotherLanguageIsOffered() {
        // The comments that went without a button on the iPhone: Thanks and I love you, read by a Thai viewer.
        #expect(CommentTranslation.source(for: Comment(body: "Thanks"), target: thai) == .known("en"))
        #expect(CommentTranslation.source(for: Comment(body: "I love you"), target: thai) == .known("en"))
        #expect(CommentTranslation.source(for: Comment(body: "Gracias!"), target: english) == .known("es"))
    }

    @Test func aShortCommentTooUnsureToNameLetsAppleTranslationDetectIt() {
        #expect(CommentTranslation.source(for: Comment(body: "ok"), target: thai) == .detectedByTranslation)
        #expect(CommentTranslation.source(for: Comment(body: "nice"), target: thai) == .detectedByTranslation)
    }

    @Test func aShortCommentInTheViewersLanguageIsNotOffered() {
        #expect(CommentTranslation.source(for: Comment(body: "สวยมาก"), target: thai) == nil)
        #expect(CommentTranslation.source(for: Comment(body: "Thanks"), target: english) == nil)
        // Only a 20% guess of English, but English all the same: no translation into itself.
        #expect(CommentTranslation.source(for: Comment(body: "nice"), target: english) == nil)
    }

    @Test func aCommentWithoutWordsIsNotOffered() {
        #expect(CommentTranslation.source(for: Comment(body: "👍👍👍👍👍👍👍👍👍👍👍👍👍"), target: english) == nil)
        #expect(CommentTranslation.source(for: Comment(body: "555"), target: english) == nil)
    }

    @Test func commentsOpenInTheLanguageOfTheViewersCountry() {
        #expect(CommentTranslation.language(forCountry: "TH") == .thai)
        #expect(CommentTranslation.language(forCountry: "th") == .thai)
        #expect(CommentTranslation.language(forCountry: "US") == .english)
        #expect(CommentTranslation.language(forCountry: "ES") == .spanish)
        // On the owner's iPhone (region Thailand) the English comments are translated into Thai.
        let target = CommentTranslation.language(forCountry: "TH")
        #expect(CommentTranslation.source(for: Comment(body: "Thanks"), target: target) == .known("en"))
        #expect(CommentTranslation.source(for: Comment(body: "สวยมาก"), target: target) == nil)
    }

    @Test func anUnknownCountryHasNoLanguage() {
        #expect(CommentTranslation.language(forCountry: nil) == nil)
        #expect(CommentTranslation.language(forCountry: "") == nil)
        #expect(CommentTranslation.language(forCountry: "THA") == nil)
    }

    @Test func chineseVariantsCountAsTheSameLanguageAsTheViewers() {
        let comment = Comment(body: "这个地方太美了", language: "zh-Hans")
        let chinese = ListeningLanguage(identifier: "zh-Hant")
        #expect(CommentTranslation.source(for: comment, target: chinese) == nil)
        #expect(CommentTranslation.source(for: comment, target: english) == .known("zh-Hans"))
    }
}
