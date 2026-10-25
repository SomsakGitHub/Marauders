import Foundation
import Testing
@testable import Marauders

@MainActor
struct SpokenLanguageCatalogTests {
    @Test func codesAreUniqueLowercaseAndAcceptedByTheApi() {
        #expect(Set(SpokenLanguageCatalog.codes).count == SpokenLanguageCatalog.codes.count)
        for code in SpokenLanguageCatalog.codes {
            #expect(code == code.lowercased())
            #expect(code.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil)
        }
    }

    @Test func everyDubbableAndCommonLanguageIsOffered() {
        let codes = Set(SpokenLanguageCatalog.codes)
        for required in ["en", "es", "th", "de", "fr", "it", "ja", "ko", "pt", "zh"] { #expect(codes.contains(required)) }
    }

    @Test func optionsAreNamedAndSortedByLocalizedName() {
        let english = Locale(identifier: "en")
        let options = SpokenLanguageCatalog.options(locale: english)
        #expect(options.count == SpokenLanguageCatalog.codes.count)
        #expect(options.allSatisfy { !$0.name.isEmpty })
        #expect(options.first { $0.code == "es" }?.name == "Spanish")
        let names = options.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func namesFollowTheDeviceLanguage() {
        #expect(SpokenLanguageCatalog.name(for: "es", locale: Locale(identifier: "th")) == "สเปน")
    }

    @Test func aDetectedCodeOutsideTheCatalogGetsItsOwnRowExactlyOnce() {
        let options = SpokenLanguageCatalog.options(including: "ZH-Hans", locale: Locale(identifier: "en"))
        #expect(options.filter { $0.code == "zh-hans" }.count == 1)
        #expect(SpokenLanguageCatalog.options(including: "es", locale: Locale(identifier: "en")).count == SpokenLanguageCatalog.codes.count)
        #expect(SpokenLanguageCatalog.options(including: nil).count == SpokenLanguageCatalog.codes.count)
    }

    @Test func unknownCodesFallBackToTheCodeItself() {
        #expect(SpokenLanguageCatalog.name(for: "zzzz-qq", locale: Locale(identifier: "en")).isEmpty == false)
    }
}
