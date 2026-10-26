import Foundation
import Testing
@testable import Marauders

struct AcousticLanguagePolicyTests {
    private func guess(_ code: String, _ probability: Double) -> AcousticLanguageGuess {
        AcousticLanguageGuess(code: code, probability: probability)
    }

    @Test func aConfidentWindowIsAccepted() {
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.99)]) == guess("nl", 0.99))
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.8)])?.code == "nl")
    }

    @Test func anUnsureWindowIsNotAcceptedAndNeitherIsNothing() {
        // The one wrong answer in the measurement (Norwegian read as Turkish) had base probability 0.24.
        #expect(AcousticLanguagePolicy.decide([guess("tr", 0.24)]) == nil)
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.79)]) == nil)
        #expect(AcousticLanguagePolicy.decide([]) == nil)
    }

    @Test func windowsMustAgreeAndTheirMeanMustReachTheThreshold() {
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.9), guess("nl", 0.7)])?.probability == 0.8)
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.9), guess("nl", 0.6)]) == nil)
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.99), guess("de", 0.99)]) == nil)
    }

    @Test func onlyStrongAnswersAreWorthRemembering() {
        #expect(AcousticLanguagePolicy.rememberAbove > AcousticLanguagePolicy.acceptance)
        #expect(AcousticLanguagePolicy.rememberAbove == 0.95)
    }

    @Test func norwegianLabelsBecomeBokmal() {
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "no") == "nb")
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "nn") == "nb")
        // Two windows labelled differently but meaning the same language still agree.
        #expect(AcousticLanguagePolicy.decide([guess("no", 0.9), guess("nn", 0.9)])?.code == "nb")
    }

    @Test func otherLabelsAreMappedOrDroppedNotShownVerbatim() {
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "TL") == "fil")
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "iw") == "he")
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "nl") == "nl")
        // Whisper knows Latin and Javanese; the app does not name them.
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "la") == nil)
        #expect(AcousticLanguagePolicy.appCode(forModelLabel: "jw") == nil)
        #expect(AcousticLanguagePolicy.decide([guess("la", 0.99)]) == nil)
        #expect(AcousticLanguagePolicy.decide([guess("nl", 0.99), guess("la", 0.99)]) == nil)
    }

    @MainActor @Test func everyListeningLanguageIsNamed() {
        for language in ListeningLanguage.all {
            #expect(AcousticLanguagePolicy.namedLanguages.contains(language.code), "\(language.code) is a listening language")
        }
    }
}

struct AcousticClipLanguageDetectorTests {
    private final class Scripted: AcousticLanguageIdentifying, @unchecked Sendable {
        nonisolated(unsafe) var answers: [AcousticLanguageGuess?]
        nonisolated(unsafe) private(set) var asked: [URL] = []
        nonisolated init(_ answers: [AcousticLanguageGuess?]) { self.answers = answers }
        nonisolated func identify(window: URL) async -> AcousticLanguageGuess? {
            asked.append(window)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private let windows = [URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.wav")]

    @Test func windowsTheModelCouldNotReadAreSkipped() async {
        let identifier = Scripted([nil, .init(code: "ru", probability: 0.92)])
        let result = await AcousticClipLanguageDetector(identifier: identifier).detect(windows: windows)
        #expect(result == .init(code: "ru", probability: 0.92))
        #expect(identifier.asked == windows)
    }

    @Test func noWindowsAndNoModelGiveNoAnswer() async {
        #expect(await AcousticClipLanguageDetector(identifier: Scripted([])).detect(windows: windows) == nil)
        #expect(await AcousticClipLanguageDetector(identifier: NoopAcousticLanguageIdentifier()).detect(windows: windows) == nil)
        #expect(await AcousticClipLanguageDetector(identifier: Scripted([.init(code: "ru", probability: 0.99)])).detect(windows: []) == nil)
    }
}
