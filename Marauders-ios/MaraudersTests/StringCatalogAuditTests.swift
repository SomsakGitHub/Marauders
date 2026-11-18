//
//  StringCatalogAuditTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What the catalog guard reports, on small catalogs written here. The real catalogs are checked in
/// `LocalizationCatalogTests`.
struct StringCatalogAuditTests {
    /// A catalog whose `strings` object holds `entries` (JSON, without the braces).
    private func audit(_ entries: String) throws -> StringCatalogAudit {
        try StringCatalogAudit(data: Data(#"{"sourceLanguage":"en","strings":{\#(entries)},"version":"1.0"}"#.utf8))
    }

    private func thai(_ value: String) -> String {
        #"{"localizations":{"th":{"stringUnit":{"state":"translated","value":"\#(value)"}}}}"#
    }

    private func problem(_ key: String, _ reason: String) -> StringCatalogAudit.Problem {
        StringCatalogAudit.Problem(key: key, reason: reason)
    }

    // MARK: - A key without Thai

    @Test func keyWithoutThaiIsReported() throws {
        let audit = try audit(
            #"""
            "Feed": \#(thai("ฟีด")),
            "Sign in required": {},
            "Upload": {"localizations":{"en":{"stringUnit":{"state":"translated","value":"Upload"}}}}
            """#)

        #expect(audit.problems() == [problem("Sign in required", "no th text"), problem("Upload", "no th text")])
    }

    @Test func emptyThaiIsReported() throws {
        let audit = try audit(#""Feed": \#(thai("")), "Map": \#(thai("   "))"#)

        #expect(audit.problems() == [problem("Feed", "no th text"), problem("Map", "no th text")])
    }

    @Test func dontTranslateKeyIsExempt() throws {
        let audit = try audit(#""View Log": {"shouldTranslate": false}"#)

        #expect(audit.problems().isEmpty)
    }

    @Test func staleKeyIsExempt() throws {
        let audit = try audit(#""Retry": {"extractionState": "stale"}"#)

        #expect(audit.problems().isEmpty)
    }

    @Test func aThaiTextInPluralVariationsCounts() throws {
        let audit = try audit(
            #"""
            "%lld clips": {"localizations":{"th":{"variations":{"plural":{
                "other":{"stringUnit":{"state":"translated","value":"%lld คลิป"}}}}}}}
            """#)

        #expect(audit.problems().isEmpty)
    }

    // MARK: - Placeholders

    @Test func samePlaceholdersPass() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("%@ มี %lld คลิป"))"#)

        #expect(audit.problems().isEmpty)
    }

    @Test func missingPlaceholderIsReported() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("มี %lld คลิป"))"#)

        #expect(audit.problems() == [problem("%@ has %lld clips", "placeholders differ")])
    }

    @Test func aPlaceholderOfAnotherTypeIsReported() throws {
        let audit = try audit(#""%lld clips": \#(thai("%@ คลิป"))"#)

        #expect(audit.problems() == [problem("%lld clips", "placeholders differ")])
    }

    @Test func swappedTypesWithoutPositionsAreReported() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("%lld คลิปของ %@"))"#)

        #expect(audit.problems() == [problem("%@ has %lld clips", "placeholders differ")])
    }

    @Test func positionalReorderPasses() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("%2$lld คลิปของ %1$@"))"#)

        #expect(audit.problems().isEmpty)
    }

    @Test func aPositionThatPointsAtAnotherTypeIsReported() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("%1$lld คลิปของ %2$@"))"#)

        #expect(audit.problems() == [problem("%@ has %lld clips", "placeholders differ")])
    }

    @Test func positionsMixedWithPlainPlaceholdersAreReported() throws {
        let audit = try audit(#""%@ has %lld clips": \#(thai("%2$lld คลิปของ %@"))"#)

        #expect(audit.problems() == [problem("%@ has %lld clips", "placeholders differ")])
    }

    @Test func percentLiteralIsIgnored() throws {
        let audit = try audit(
            #"""
            "100%% sure, %@": \#(thai("แน่ใจ 100%% %@")),
            "Uploading… %lld%%": \#(thai("กำลังอัปโหลด… %lld%%"))
            """#)

        #expect(audit.problems().isEmpty)
    }

    @Test func aPlaceholderWithAPrecisionKeepsItsType() throws {
        let audit = try audit(#""%.1f km away": \#(thai("ห่าง %.1f กม.")), "%lf km": \#(thai("%lld กม."))"#)

        #expect(audit.problems() == [problem("%lf km", "placeholders differ")])
    }

    @Test func theEnglishValueOfASymbolicKeyIsTheReference() throws {
        let audit = try audit(
            #"""
            "profile.greeting": {"localizations":{
                "en":{"stringUnit":{"state":"translated","value":"Hello %@"}},
                "th":{"stringUnit":{"state":"translated","value":"สวัสดี"}}}}
            """#)

        #expect(audit.problems() == [problem("profile.greeting", "placeholders differ")])
    }

    // MARK: - The Info.plist catalog

    @Test func infoPlistLanguagesAreChecked() throws {
        let audit = try audit(
            #"""
            "NSCameraUsageDescription": {"localizations":{
                "en":{"stringUnit":{"state":"translated","value":"Record a clip"}},
                "th":{"stringUnit":{"state":"translated","value":"ถ่ายคลิป"}}}},
            "NSMicrophoneUsageDescription": {"localizations":{
                "en":{"stringUnit":{"state":"translated","value":"Record sound"}}}}
            """#)

        let problems = audit.missing(
            languages: ["en", "th"],
            forKeys: ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"])

        #expect(
            problems == [
                problem("NSMicrophoneUsageDescription", "no th text"),
                problem("NSPhotoLibraryUsageDescription", "no en text"),
                problem("NSPhotoLibraryUsageDescription", "no th text"),
            ])
    }

    @Test func aKeyAndItsTextInALanguageCanBeLookedUp() throws {
        let audit = try audit(#""Feed": \#(thai("ฟีด")), "Map": {"shouldTranslate": false}, "Blank": \#(thai("  "))"#)

        #expect(audit.hasKey("Feed"))
        #expect(audit.hasKey("Map"))
        #expect(!audit.hasKey("Nothing"))
        #expect(audit.text(forKey: "Feed", language: "th") == "ฟีด")
        #expect(audit.text(forKey: "Feed", language: "en") == nil)
        #expect(audit.text(forKey: "Map", language: "th") == nil)
        #expect(audit.text(forKey: "Blank", language: "th") == nil)
        #expect(audit.text(forKey: "Nothing", language: "th") == nil)
    }

    @Test func aProblemDescribesItselfWithItsKey() {
        #expect(problem("Feed", "no th text").description == "Feed: no th text")
    }

    @Test func aFileThatIsNotACatalogThrows() {
        #expect(throws: (any Error).self) { try StringCatalogAudit(data: Data("not a catalog".utf8)) }
    }
}
