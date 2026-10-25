import Foundation
import Testing
@testable import Marauders

@MainActor
struct DetectedLanguageMemoTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "tests.\(UUID().uuidString)")! }

    @Test func remembersALanguagePerClipAcrossInstances() {
        let store = defaults()
        let first = UUID(), second = UUID()
        let memo = DetectedLanguageMemo(defaults: store)
        #expect(memo.code(for: first) == nil)
        memo.remember("es", for: first)
        memo.remember("en", for: second)
        #expect(memo.code(for: first) == "es")
        let reopened = DetectedLanguageMemo(defaults: store)
        #expect(reopened.code(for: first) == "es")
        #expect(reopened.code(for: second) == "en")
    }

    @Test func rememberingAgainReplacesTheLanguage() {
        let memo = DetectedLanguageMemo(defaults: defaults())
        let id = UUID()
        memo.remember("es", for: id)
        memo.remember("en", for: id)
        #expect(memo.code(for: id) == "en")
    }

    @Test func theOldestEntriesAreDroppedPastTheLimit() {
        let store = defaults()
        let memo = DetectedLanguageMemo(defaults: store, limit: 3)
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() { memo.remember(index.isMultiple(of: 2) ? "en" : "es", for: id) }
        #expect(memo.code(for: ids[0]) == nil)
        #expect(memo.code(for: ids[1]) == nil)
        #expect(memo.code(for: ids[2]) == "en")
        #expect(memo.code(for: ids[4]) == "en")
        #expect(DetectedLanguageMemo(defaults: store, limit: 3).code(for: ids[3]) == "es")
        #expect(DetectedLanguageMemo(defaults: store, limit: 3).code(for: ids[0]) == nil)
    }

    @Test func aTouchedClipIsTheNewestNotTheOldest() {
        let memo = DetectedLanguageMemo(defaults: defaults(), limit: 2)
        let a = UUID(), b = UUID(), c = UUID()
        memo.remember("en", for: a)
        memo.remember("es", for: b)
        memo.remember("en", for: a)
        memo.remember("es", for: c)
        #expect(memo.code(for: a) == "en")
        #expect(memo.code(for: b) == nil)
        #expect(memo.code(for: c) == "es")
    }

    @Test func idsAreCaseInsensitiveAndCorruptStorageIsIgnored() {
        let store = defaults()
        store.set(["order": ["a"], "codes": []], forKey: "detectedClipLanguages")
        let memo = DetectedLanguageMemo(defaults: store)
        let id = UUID()
        memo.remember("en", for: id)
        #expect(memo.code(for: id) == "en")
        store.set("not a dictionary", forKey: "detectedClipLanguages")
        #expect(DetectedLanguageMemo(defaults: store).code(for: id) == nil)
    }
}
