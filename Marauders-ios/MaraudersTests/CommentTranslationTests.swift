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
        #expect(CommentTranslation.sourceCode(for: comment, target: english) == "es")
    }

    @Test func aDeclaredLanguageThatIsTheViewersIsNotOffered() {
        let comment = Comment(body: "hello", language: "en-GB")
        #expect(CommentTranslation.sourceCode(for: comment, target: english) == nil)
    }

    @Test func aDeclaredLanguageWeCannotTranslateIsNotOffered() {
        let comment = Comment(body: "Ceci n'est pas un test", language: "xx")
        // Falls back to detection, which finds French.
        #expect(CommentTranslation.sourceCode(for: comment, target: english) == "fr")
        let unknown = Comment(body: "short", language: "xx")
        #expect(CommentTranslation.sourceCode(for: unknown, target: english) == nil)
    }

    @Test func aViewerWithoutAListeningLanguageIsOfferedNothing() {
        let comment = Comment(body: "hola", language: "es")
        #expect(CommentTranslation.sourceCode(for: comment, target: nil) == nil)
    }

    @Test func anUndeclaredLanguageIsDetectedOnTheIPhone() {
        let spanish = Comment(body: "Este lugar es increíble, volveremos pronto")
        #expect(CommentTranslation.sourceCode(for: spanish, target: english) == "es")
        let thaiText = Comment(body: "ที่นี่สวยมาก อยากกลับไปอีกครั้ง")
        #expect(CommentTranslation.sourceCode(for: thaiText, target: english) == "th")
    }

    @Test func detectedTextInTheViewersLanguageIsNotOffered() {
        let comment = Comment(body: "This place is incredible, we will be back soon")
        #expect(CommentTranslation.sourceCode(for: comment, target: english) == nil)
        let thaiText = Comment(body: "ที่นี่สวยมาก อยากกลับไปอีกครั้ง")
        #expect(CommentTranslation.sourceCode(for: thaiText, target: thai) == nil)
    }

    @Test func textTooShortToDetectIsNotOffered() {
        #expect(CommentTranslation.sourceCode(for: Comment(body: "Gracias!"), target: english) == nil)
        #expect(CommentTranslation.sourceCode(for: Comment(body: "👍👍👍👍👍👍👍👍👍👍👍👍👍"), target: english) == nil)
    }

    @Test func chineseVariantsCountAsTheSameLanguageAsTheViewers() {
        let comment = Comment(body: "这个地方太美了", language: "zh-Hans")
        let chinese = ListeningLanguage(identifier: "zh-Hant")
        #expect(CommentTranslation.sourceCode(for: comment, target: chinese) == nil)
        #expect(CommentTranslation.sourceCode(for: comment, target: english) == "zh-Hans")
    }
}
