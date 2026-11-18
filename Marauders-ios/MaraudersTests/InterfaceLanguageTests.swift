//
//  InterfaceLanguageTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders

/// The name Settings shows for the language the app's own texts are in.
@MainActor
struct InterfaceLanguageTests {
    @Test func aLanguageIsNamedInItsOwnWords() {
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["th"]) == "ไทย")
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["en"]) == "English")
    }

    @Test func aNameStartsWithACapitalLetter() {
        // French writes "français"; a row of Settings starts it with a capital, as iOS's own list of languages does.
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["fr"]) == "Français")
    }

    @Test func theBaseLocalizationIsSkipped() {
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["Base", "th"]) == "ไทย")
    }

    /// The app's texts are English wherever no other language applies, so that is the name to show.
    @Test func nothingUsableMeansEnglish() {
        #expect(InterfaceLanguage.currentName(preferredLocalizations: []) == "English")
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["Base"]) == "English")
        #expect(InterfaceLanguage.currentName(preferredLocalizations: ["zz"]) == "English")
    }

    /// The test host runs in English: the shared scheme pins it.
    @Test func theAppsOwnBundleGivesItsLanguage() {
        #expect(InterfaceLanguage.currentName() == "English")
    }
}
