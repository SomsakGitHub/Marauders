import Foundation
import Testing

@testable import Marauders

/// The use case only hands the kept answer and the fresh answer to the rule together with this build's number and
/// kind. What the rule says is pinned in `UpdateDecisionTests`; what the screen does with it in
/// `UpdateGateViewModelTests`.
@MainActor
struct CheckUpdateRequirementUseCaseTests {
    private let appStore = URL(string: "https://apps.apple.com/app/id1234567890")!

    private var armed: AppConfig { AppConfig(minimumBuild: 10, updateURL: appStore) }
    private var lifted: AppConfig { AppConfig(minimumBuild: 0, updateURL: nil) }

    private func useCase(
        _ repository: FakeAppConfigRepository, build: Int? = 9, isDebugBuild: Bool = false
    ) -> CheckUpdateRequirementUseCase {
        CheckUpdateRequirementUseCase(repository: repository, currentBuild: build, isDebugBuild: isDebugBuild)
    }

    @Test func theKeptAnswerDecidesAtOnceAndNothingIsAsked() {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [])
        #expect(useCase(repository).cached() == .required(updateURL: appStore))
        #expect(repository.refreshCount == 0)
    }

    @Test func nothingKeptIsAllowed() {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [])
        #expect(useCase(repository).cached() == .allowed)
    }

    /// The same kept answer, judged by this build's own number and kind.
    @Test func theKeptAnswerIsJudgedByThisBuild() {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [])
        #expect(useCase(repository, build: 10).cached() == .allowed, "equal is allowed")
        #expect(
            useCase(repository, build: 1).cached() == .required(updateURL: appStore),
            "build 1 is judged like any other")
        #expect(useCase(repository, build: nil).cached() == .allowed, "no number, no stop")
        #expect(useCase(repository, isDebugBuild: true).cached() == .allowed, "a debug build is never stopped")
    }

    /// RF1: a refresh that failed says so, so the caller keeps what it shows instead of reading "allowed".
    @Test func aRefreshThatFailedIsNoDecision() async {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [nil])
        let decision = await useCase(repository).refresh()
        #expect(decision == nil)
        #expect(repository.refreshCount == 1)
    }

    @Test func aFreshAnswerIsJudgedAgain() async {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [armed])
        #expect(await useCase(repository).refresh() == .required(updateURL: appStore))
    }

    /// RF2: the minimum is cleared in the console and the next answer lifts the screen.
    @Test func aFreshAnswerWithMinimumZeroLiftsTheStop() async {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [lifted])
        #expect(await useCase(repository).refresh() == .allowed)
    }
}
