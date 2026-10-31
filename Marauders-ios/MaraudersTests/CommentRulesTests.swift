//
//  CommentRulesTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct CommentRulesTests {
    @Test func normalizedTrimsSurroundingWhitespaceAndNewlines() {
        #expect(CommentRules.normalized("  hello there \n") == "hello there")
    }

    @Test func normalizedKeepsInnerLineBreaks() {
        #expect(CommentRules.normalized("one\ntwo") == "one\ntwo")
    }

    @Test func normalizedRejectsEmptyAndBlankText() {
        #expect(CommentRules.normalized("") == nil)
        #expect(CommentRules.normalized("   \n\t ") == nil)
    }

    @Test func normalizedRejectsTextNobodyCanSee() {
        // Zero-width and directional marks, variation selectors, the Braille blank and the Hangul fillers draw nothing,
        // so a comment made of them would post as an empty-looking row. The Worker refuses the same set.
        let invisible = [
            "\u{200B}", "\u{200B}\u{200B}\u{200B}", "\u{200C}\u{200D}", "\u{200E}\u{200F}", "\u{2060}", "\u{FEFF}",
            "\u{00AD}", "\u{2800}", "\u{3164}", "\u{115F}\u{1160}", "\u{FFA0}", " \u{200B} \u{00A0} \n", "\u{2028}\u{2029}",
            "\u{FE0F}", "\u{FE00}\u{FE0E}", "\u{034F}", "\u{FFFC}", "\u{0000}", "\u{0007}\u{0000}", "\u{0085}",
            // Trimming leaves whitespace that sits between invisible characters (U+200B itself is trimmed, so these
            // use U+200C and U+2060), and C1 controls draw nothing.
            "\u{200C} \u{200C}", "\u{2060}\u{00A0}\u{2060}", "\u{2060}\u{2028}\u{2060}", "\u{0080}", "\u{009B}\u{200C}",
        ]
        for text in invisible {
            #expect(CommentRules.normalized(text) == nil, "\(text.unicodeScalars.map(\.value))")
        }
    }

    @Test func normalizedKeepsInvisibleCharactersThatSitInsideRealText() {
        #expect(CommentRules.normalized("ไม่\u{200C}ได้ 👍🏽") == "ไม่\u{200C}ได้ 👍🏽")
        #expect(CommentRules.normalized("a\u{200B}b") == "a\u{200B}b")
        #expect(CommentRules.normalized("\u{3164}hi\u{3164}") == "\u{3164}hi\u{3164}")
        #expect(CommentRules.normalized("\u{2800}ok") == "\u{2800}ok")
    }

    @Test func normalizedAcceptsTextThatDrawsSomething() {
        #expect(CommentRules.normalized("👨‍👩‍👧‍👦") != nil)
        #expect(CommentRules.normalized("😀") != nil)
        #expect(CommentRules.normalized("สวัสดีครับ") != nil)
        #expect(CommentRules.normalized("ก้") != nil)
        #expect(CommentRules.normalized("\u{0E49}") != nil)
        #expect(CommentRules.normalized("مرحبا") != nil)
        #expect(CommentRules.normalized("…") != nil)
    }

    @Test func normalizedAcceptsExactlyTheLimit() {
        let atLimit = String(repeating: "a", count: CommentRules.maxCharacters)
        #expect(CommentRules.normalized(atLimit) == atLimit)
    }

    @Test func normalizedRejectsOneOverTheLimit() {
        let overLimit = String(repeating: "a", count: CommentRules.maxCharacters + 1)
        #expect(CommentRules.normalized(overLimit) == nil)
    }

    @Test func limitIgnoresTrailingWhitespace() {
        let padded = String(repeating: "a", count: CommentRules.maxCharacters) + "   \n"
        #expect(CommentRules.normalized(padded)?.count == CommentRules.maxCharacters)
    }

    @Test func characterCountUsesUnicodeScalarsLikeTheWorker() {
        // The Worker counts JavaScript code points: a family emoji is 7 of them, though Swift sees one Character.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1)
        #expect(CommentRules.characterCount(family) == 7)
        #expect(CommentRules.characterCount("สวัสดี") == 6)
    }

    @Test func emojiSequencesCountTowardTheLimit() {
        let family = "👨‍👩‍👧‍👦"
        let fits = String(repeating: family, count: CommentRules.maxCharacters / 7)
        let tooMany = fits + family
        #expect(CommentRules.normalized(fits) == fits)
        #expect(CommentRules.normalized(tooMany) == nil)
    }
}
