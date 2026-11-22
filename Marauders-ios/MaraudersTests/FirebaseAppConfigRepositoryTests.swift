import Foundation
import Testing

@testable import Marauders

private let linkText = "https://apps.apple.com/app/id1"

/// What the console publishes for the minimum build, and what the app reads of it: `(the text, the number it counts as)`.
/// Only digits count (the rule of the build's own number); every other text, an empty one included, counts as 0.
private let minimumTexts: [(String, Int)] = [
    ("12", 12), (" 7\n", 7), ("0", 0), ("", 0), ("12o", 0), ("1.5", 0), ("-3", 0), ("+5", 0),
    ("99999999999999999999", 0),
]

/// `(the text of update_url, the link the app keeps)`: spaces and line breaks around it are ignored, and an empty
/// link is none.
private let linkTexts: [(String, URL?)] = [
    ("", nil), ("   ", nil), (" \(linkText)\n", URL(string: linkText)),
]

/// What the app reads from Firebase Remote Config and keeps (docs/adr/012-force-update.md): the repository that turns
/// the two published texts into an `AppConfig` and keeps the last good one in UserDefaults. Only an answer counts;
/// every failure leaves what is kept as it was (RF1), and a published 0 or a removed parameter replaces a kept minimum
/// (RF2).
@MainActor
struct FirebaseAppConfigRepositoryTests {
    private let link = URL(string: linkText)!

    private func repository(_ source: FakeRemoteConfigSource, _ defaults: UserDefaults) -> FirebaseAppConfigRepository {
        FirebaseAppConfigRepository(source: source, defaults: defaults)
    }

    private func published(_ minimumBuild: String, _ updateURL: String = linkText) -> RemoteConfigValues {
        RemoteConfigValues(minimumBuild: minimumBuild, updateURL: updateURL)
    }

    @Test func nothingIsKeptBeforeTheFirstRefresh() {
        let suite = ThrowawayDefaults()

        #expect(repository(FakeRemoteConfigSource([]), suite.defaults).cached() == nil)
    }

    @Test func aGoodAnswerIsReturnedAndKeptAcrossALaunch() async {
        let suite = ThrowawayDefaults()
        let launch = repository(FakeRemoteConfigSource([published("12")]), suite.defaults)
        let expected = AppConfig(minimumBuild: 12, updateURL: link)

        #expect(await launch.refresh() == expected)
        #expect(suite.defaults.data(forKey: FirebaseAppConfigRepository.defaultsKey) != nil)

        // A new repository on the same defaults is the next launch: the kept answer is there with no fetch at all.
        let source = FakeRemoteConfigSource([nil])
        let nextLaunch = repository(source, suite.defaults)
        #expect(nextLaunch.cached() == expected)
        #expect(source.fetchCount == 0)
    }

    @Test(arguments: minimumTexts)
    func theMinimumIsParsedLikeTheBuildNumber(text: String, expected: Int) async throws {
        let suite = ThrowawayDefaults()
        let repository = repository(FakeRemoteConfigSource([published(text)]), suite.defaults)

        let config = try #require(await repository.refresh())

        #expect(config.minimumBuild == expected, "\(text.debugDescription) counts as \(expected)")
    }

    @Test(arguments: linkTexts)
    func theLinkIsTrimmedAndAnEmptyOneIsNone(text: String, expected: URL?) async throws {
        let suite = ThrowawayDefaults()
        let repository = repository(FakeRemoteConfigSource([published("12", text)]), suite.defaults)

        let config = try #require(await repository.refresh())

        #expect(config.updateURL == expected, "\(text.debugDescription) is \(String(describing: expected))")
    }

    /// RF2: a parameter that was never published, or was deleted, reads as no gate, and that is an answer: it is kept.
    @Test func anAbsentParameterReadsAsNoGate() async throws {
        let suite = ThrowawayDefaults()
        let repository = repository(FakeRemoteConfigSource([published("", "")]), suite.defaults)
        let noGate = AppConfig(minimumBuild: 0, updateURL: nil)

        #expect(try #require(await repository.refresh()) == noGate)

        #expect(repository.cached() == noGate)
    }

    /// RF2: the owner lowers or clears the minimum, and what is kept follows, so the screen lifts at the next launch
    /// without waiting for another refresh.
    @Test func aClearedMinimumReplacesAKeptMinimum() async {
        let suite = ThrowawayDefaults()
        let source = FakeRemoteConfigSource([published("99"), published("0", "")])
        let repository = repository(source, suite.defaults)
        #expect(await repository.refresh() == AppConfig(minimumBuild: 99, updateURL: link))

        let lifted = AppConfig(minimumBuild: 0, updateURL: nil)
        #expect(await repository.refresh() == lifted)

        #expect(repository.cached() == lifted)
    }

    /// RF1: no network, a throttled or timed-out fetch or an unusable plist must not undo a "required" the app already
    /// knows.
    @Test func aFailedRefreshReturnsNilAndKeepsTheEarlierAnswer() async {
        let suite = ThrowawayDefaults()
        let source = FakeRemoteConfigSource([published("12"), nil])
        let repository = repository(source, suite.defaults)
        let expected = AppConfig(minimumBuild: 12, updateURL: link)
        #expect(await repository.refresh() == expected)

        #expect(await repository.refresh() == nil)

        #expect(repository.cached() == expected)
        #expect(source.fetchCount == 2)
    }

    @Test func aFirstRefreshThatFailsKeepsNothing() async {
        let suite = ThrowawayDefaults()
        let repository = repository(FakeRemoteConfigSource([nil]), suite.defaults)

        #expect(await repository.refresh() == nil)

        #expect(suite.defaults.object(forKey: FirebaseAppConfigRepository.defaultsKey) == nil)
    }

    /// The SDK's fetch cannot be cancelled, so it may still answer after the task that asked has been cancelled: that
    /// answer is dropped, as a failure is.
    @Test func aCancelledRefreshKeepsNothing() async {
        let suite = ThrowawayDefaults()
        let source = FakeRemoteConfigSource([published("12")], cancelsWhileFetching: true)
        let repository = repository(source, suite.defaults)

        let result = await Task { await repository.refresh() }.value

        #expect(result == nil)
        #expect(source.fetchCount == 1)
        #expect(suite.defaults.object(forKey: FirebaseAppConfigRepository.defaultsKey) == nil)
    }

    /// The log line says whether Google was asked or the SDK answered from what it saved (the owner read "refreshed" and
    /// took a saved 5 for a fresh one, 2026-11-22). A source that cannot tell, like every stand-in, adds nothing.
    @Test func theLogSaysWhereTheAnswerCameFrom() async {
        let suite = ThrowawayDefaults()
        let asked = RemoteConfigValues(minimumBuild: "4201", updateURL: linkText, origin: .google)
        let saved = RemoteConfigValues(
            minimumBuild: "4202", updateURL: linkText, origin: .saved(lastAsked: Date().addingTimeInterval(-90)))
        let unknown = RemoteConfigValues(minimumBuild: "4203", updateURL: linkText)
        let repository = repository(FakeRemoteConfigSource([asked, saved, unknown]), suite.defaults)

        _ = await repository.refresh()
        _ = await repository.refresh()
        _ = await repository.refresh()

        #expect(await logged("config refreshed: minimumBuild=4201 (from Google)"))
        #expect(
            await logged(
                "config refreshed: minimumBuild=4202 (from the SDK's saved values, Google last asked 1 min ago)"))
        #expect(await logged("config refreshed: minimumBuild=4203"))
    }

    /// `AppLog` writes from a task of its own, so a line shows up a moment after the call that logged it.
    private func logged(_ message: String) async -> Bool {
        for _ in 0..<300 {
            if AppLogStore.shared.entries.contains(where: { $0.category == "update" && $0.message == message }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// RF1: an entry that is not an answer any more (an older shape, a damaged value) counts as none and is dropped, so
    /// it is not met again at the next launch.
    @Test func anEntryThatNoLongerDecodesIsRemoved() {
        let suite = ThrowawayDefaults()
        let repository = repository(FakeRemoteConfigSource([]), suite.defaults)
        let key = FirebaseAppConfigRepository.defaultsKey

        let broken: [Any] = [Data("garbage".utf8), Data(), Data(#"{"minimumBuild":"x"}"#.utf8), "a string", 42]
        for entry in broken {
            suite.defaults.set(entry, forKey: key)

            #expect(repository.cached() == nil, "\(entry) is no kept answer")
            #expect(suite.defaults.object(forKey: key) == nil, "\(entry) is removed")
        }
    }
}
