//
//  LocalizationCatalogTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The tests read the catalogs where they lie in the repository, through this file's own path: they run where the
/// sources are, which is a simulator and not an iPhone.
private let sourcesAreReadable: Bool = {
    #if targetEnvironment(simulator)
        return true
    #else
        return false
    #endif
}()

/// The committed string catalogs. A key without a Thai text shows English on a Thai screen, so these tests stay red
/// until every new string has its Thai (or is marked "don't translate" because only developers see it).
@MainActor
struct LocalizationCatalogTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MaraudersTests
        .deletingLastPathComponent()  // Marauders-ios
        .appending(path: "Marauders/Resources")

    private static func list(_ problems: [StringCatalogAudit.Problem]) -> Testing.Comment {
        Testing.Comment(rawValue: problems.map(\.description).joined(separator: "\n"))
    }

    @Test(.enabled(if: sourcesAreReadable))
    func everyLiveKeyHasThaiWithMatchingPlaceholders() throws {
        let catalog = try Data(contentsOf: Self.resources.appending(path: "Localizable.xcstrings"))

        let problems = try StringCatalogAudit(data: catalog).problems()

        #expect(problems.isEmpty, Self.list(problems))
    }

    @Test(.enabled(if: sourcesAreReadable))
    func infoPlistCatalogHasEnglishAndThaiForEveryUsageText() throws {
        let keys = AppBundleLocalizationTests.usageTextKeys
        #expect(!keys.isEmpty)
        let catalog = try Data(contentsOf: Self.resources.appending(path: "InfoPlist.xcstrings"))

        let problems = try StringCatalogAudit(data: catalog).missing(languages: ["en", "th"], forKeys: keys)

        #expect(problems.isEmpty, Self.list(problems))
    }

    /// iOS shows the English text of `InfoPlist.xcstrings` (the built app has `en.lproj/InfoPlist.strings`, which wins
    /// over Info.plist), and App Store validation reads the `INFOPLIST_KEY_…` build setting. Each permission text
    /// lives in both places, so editing only one changes nothing on the iPhone, or nothing in review.
    @Test(.enabled(if: sourcesAreReadable))
    func theEnglishPermissionTextsOfTheCatalogAreTheBuildSettings() throws {
        let catalog = try StringCatalogAudit(
            data: Data(contentsOf: Self.resources.appending(path: "InfoPlist.xcstrings")))

        for key in AppBundleLocalizationTests.usageTextKeys {
            let setting = Bundle.main.infoDictionary?[key] as? String
            #expect(
                catalog.text(forKey: key, language: "en") == setting,
                "\(key): the en text of InfoPlist.xcstrings differs from its INFOPLIST_KEY build setting. Change both.")
        }
    }

    /// A catalog in any other layout holds the same texts, but Xcode rewrites the whole file the first time it saves
    /// it, and that diff hides the real change. `xcrun xcstringstool sync` and the Xcode editor both write the layout,
    /// with the keys in two different orders (both pass); a script that dumps JSON does not (`"key": value` instead of
    /// `"key" : value`).
    @Test(.enabled(if: sourcesAreReadable), arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func theCatalogsAreInTheLayoutXcodeWrites(file: String) throws {
        let data = try Data(contentsOf: Self.resources.appending(path: file))

        let problem = StringCatalogLayout.problem(in: data)

        #expect(problem == nil, Testing.Comment(rawValue: "\(file): \(problem ?? "")"))
    }

    /// Only a Staging build has these texts: the two sign-in buttons and the in-app log (its tab, the link to it and its
    /// screen). A sync from a Production build would drop their keys, and the next Staging sync would add them back
    /// empty (no "don't translate"), so `everyLiveKeyHasThaiWithMatchingPlaceholders` would report them. They are
    /// written `Text(verbatim:)` instead and listed in `plain-strings-allowlist.txt`. If a text that every build shows
    /// needs one of these words one day, take the word off this list and give it its key.
    @Test(.enabled(if: sourcesAreReadable))
    func textsOfDebugOnlyCodeAreNotInTheCatalog() throws {
        let catalog = try StringCatalogAudit(
            data: Data(contentsOf: Self.resources.appending(path: "Localizable.xcstrings")))

        for key in [
            "Sign in as test user (%@)",
            "Complete test sign in",
            "Log",
            "View Log",
            "No logs yet",
            "Upload or open the feed — events appear here",
            "Clear",
            "Copy All",
            "Paste into chat or Notes",
        ] {
            #expect(!catalog.hasKey(key), "\(key) is Debug-only code: write it Text(verbatim:), not as a catalog key")
        }
    }

    /// Thai puts the word for "language" before a language's name: "จากภาษาอังกฤษ", not "จากอังกฤษ". The name in this
    /// caption comes from `Locale` and carries no such word.
    @Test(.enabled(if: sourcesAreReadable))
    func theCaptionOfATranslatedCommentPutsTheWordForLanguageBeforeItsName() throws {
        let catalog = try StringCatalogAudit(
            data: Data(contentsOf: Self.resources.appending(path: "Localizable.xcstrings")))

        let thai = catalog.text(forKey: "Translated on this iPhone from %@", language: "th")

        #expect(thai?.contains("ภาษา%@") == true, "Thai text: \(thai ?? "none")")
    }
}
