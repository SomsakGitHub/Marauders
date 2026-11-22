import Foundation
import Testing

@testable import Marauders

/// How the gate is put together for a real launch (docs/adr/012-force-update.md): what the last launch kept decides at
/// once and without asking Firebase, a debug build is exempt (a local Release build, which is build 1, is stopped like
/// any other), and a refresh asks the source once. The UI-test mode of the composition is exercised by the UI tests,
/// which can pass the launch arguments.
@MainActor
struct UpdateGateCompositionTests {
    private let appStore = URL(string: "https://apps.apple.com/app/id1")!

    /// A suite whose kept answer says "build 99 is the oldest that may run", as a launch after a refresh finds it.
    private func suiteKeepingMinimum99() throws -> ThrowawayDefaults {
        let suite = ThrowawayDefaults()
        let kept = AppConfig(minimumBuild: 99, updateURL: appStore)
        suite.defaults.set(try JSONEncoder().encode(kept), forKey: FirebaseAppConfigRepository.defaultsKey)
        return suite
    }

    @Test func theKeptAnswerStopsABuildBelowItAtOnceWithNoRequest() throws {
        let suite = try suiteKeepingMinimum99()
        let source = FakeRemoteConfigSource([])

        let gate = UpdateGateComposition.makeViewModel(
            defaults: suite.defaults, source: source, currentBuild: 2, isDebugBuild: false)

        #expect(gate.decision == .required(updateURL: appStore))
        #expect(source.fetchCount == 0, "the kept answer is read at launch, nothing waits for Firebase")
    }

    /// The test host is a debug build: the exemption is wired to the real value.
    @Test func theRealBuildOfADeveloperIsNeverStopped() throws {
        let suite = try suiteKeepingMinimum99()

        let gate = UpdateGateComposition.makeViewModel(defaults: suite.defaults, source: FakeRemoteConfigSource([]))

        #expect(gate.decision == .allowed)
    }

    /// A local Release build (a Production-scheme Run from Xcode) is build 1 and is stopped like any other.
    @Test func aLocalReleaseBuildNumberedOneIsStoppedByTheKeptAnswer() throws {
        let suite = try suiteKeepingMinimum99()

        let gate = UpdateGateComposition.makeViewModel(
            defaults: suite.defaults, source: FakeRemoteConfigSource([]), currentBuild: 1, isDebugBuild: false)

        #expect(gate.decision == .required(updateURL: appStore))
    }

    /// RF2, through the real repository: one fetch, and a minimum of 0 lifts the screen.
    @Test func aRefreshAsksTheSourceOnceAndAClearedMinimumLiftsTheScreen() async throws {
        let suite = try suiteKeepingMinimum99()
        let source = FakeRemoteConfigSource([RemoteConfigValues(minimumBuild: "0", updateURL: "")])
        let gate = UpdateGateComposition.makeViewModel(
            defaults: suite.defaults, source: source, currentBuild: 2, isDebugBuild: false)
        try #require(gate.decision == .required(updateURL: appStore))

        await gate.refreshIfDue()

        #expect(gate.decision == .allowed)
        #expect(source.fetchCount == 1)
    }
}
