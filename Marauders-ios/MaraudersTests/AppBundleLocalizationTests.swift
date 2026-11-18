//
//  AppBundleLocalizationTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The languages of the app as it is built. The unit tests are hosted in the app, so `Bundle.main` is the app bundle.
@MainActor
struct AppBundleLocalizationTests {
    /// The permission texts of Info.plist: every `NS…UsageDescription` key the built app has.
    static var usageTextKeys: [String] {
        (Bundle.main.infoDictionary ?? [:]).keys
            .filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
            .sorted()
    }

    @Test func theAppShipsEnglishAndThai() {
        #expect(Set(Bundle.main.localizations).isSuperset(of: ["en", "th"]))
    }

    /// iOS picks the app's language from the iPhone's list of languages: Thai for a Thai iPhone, and English, the
    /// development language, for an iPhone in a language the app does not have.
    @Test func languagesMapToTheAppsTwoLanguages() {
        func picked(for preferences: [String]) -> String? {
            Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        }
        #expect(picked(for: ["th-TH"]) == "th")
        #expect(picked(for: ["en-TH", "th-TH"]) == "en")
        #expect(Bundle.main.developmentLocalization == "en")
        #expect(picked(for: ["ja-JP"]) == "en")
    }

    /// Without this key iOS shows the Language row of the app's Settings page only on an iPhone with two or more
    /// preferred languages.
    @Test func theLanguageRowIsAlwaysOffered() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIPrefersShowingLanguageSettings") as? Bool == true)
    }

    @Test func everyUsageTextHasThaiInTheBuiltBundle() throws {
        let path = try #require(
            Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: "th"),
            "the app bundle has no th.lproj/InfoPlist.strings")
        let thai = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        let keys = Self.usageTextKeys
        #expect(!keys.isEmpty)
        for key in keys {
            let english = Bundle.main.infoDictionary?[key] as? String
            let text = thai[key] ?? ""
            #expect(text != english, "\(key) is still the English text")
            #expect(text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }, "\(key) has no Thai text")
        }
    }

    /// Many unit tests pin English texts. The shared scheme starts the test host with `-AppleLanguages (en)`, so they
    /// hold on a simulator or an iPhone set to Thai as well.
    @Test func theTestHostRunsInEnglish() {
        #expect(Bundle.main.preferredLocalizations.first == "en", "the shared scheme's test arguments pin English")
    }
}
