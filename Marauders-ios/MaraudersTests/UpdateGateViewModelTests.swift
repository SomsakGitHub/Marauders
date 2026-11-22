import Foundation
import Testing

@testable import Marauders

/// A clock the test moves, so the ten-minute wait is walked through without waiting.
private final class MovableClock {
    private(set) var date = Date(timeIntervalSince1970: 1_800_000_000)

    func move(byMinutes minutes: Double) {
        date = date.addingTimeInterval(minutes * 60)
    }
}

/// What decides whether the Update screen is shown (docs/adr/012-force-update.md): the view model starts from the kept
/// answer without waiting, a fresh answer replaces it, a failed one keeps it, and the Worker is asked at most once per
/// ten minutes and never twice at the same time.
@MainActor
struct UpdateGateViewModelTests {
    private let appStore = URL(string: "https://apps.apple.com/app/id1234567890")!
    private let clock = MovableClock()

    private var armed: AppConfig { AppConfig(minimumBuild: 10, updateURL: appStore) }
    private var lifted: AppConfig { AppConfig(minimumBuild: 0, updateURL: nil) }

    /// A view model for build 9, which is below `armed` and not a debug build.
    private func viewModel(_ repository: FakeAppConfigRepository) -> UpdateGateViewModel {
        UpdateGateViewModel(
            check: CheckUpdateRequirementUseCase(repository: repository, currentBuild: 9, isDebugBuild: false),
            now: { [clock] in clock.date })
    }

    // MARK: What it shows

    @Test func itStartsFromTheKeptAnswerWithoutAskingAnything() {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [])

        #expect(viewModel(repository).decision == .required(updateURL: appStore))
        #expect(repository.refreshCount == 0)
    }

    /// RF1: with nothing kept, a launch with no network or a garbage answer never blocks anyone.
    @Test func itStartsOpenWhenNothingIsKept() {
        #expect(viewModel(FakeAppConfigRepository(cached: nil, refreshResults: [])).decision == .allowed)
    }

    @Test func aFreshAnswerWithAHigherMinimumShowsTheScreen() async {
        let gate = viewModel(FakeAppConfigRepository(cached: nil, refreshResults: [armed]))

        await gate.refreshIfDue()

        #expect(gate.decision == .required(updateURL: appStore))
    }

    /// RF2: the Worker clears the minimum and the screen lifts with no relaunch.
    @Test func aFreshAnswerWithMinimumZeroLiftsTheScreen() async throws {
        let gate = viewModel(FakeAppConfigRepository(cached: armed, refreshResults: [lifted]))
        try #require(gate.decision == .required(updateURL: appStore))

        await gate.refreshIfDue()

        #expect(gate.decision == .allowed)
    }

    /// RF1: a failed refresh is not an answer, so a screen that is shown stays shown.
    @Test func aFailedRefreshKeepsAShownScreen() async {
        let repository = FakeAppConfigRepository(cached: armed, refreshResults: [nil])
        let gate = viewModel(repository)

        await gate.refreshIfDue()

        #expect(repository.refreshCount == 1)
        #expect(gate.decision == .required(updateURL: appStore))
    }

    @Test func aFailedRefreshKeepsTheGateOpen() async {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [nil])
        let gate = viewModel(repository)

        await gate.refreshIfDue()

        #expect(repository.refreshCount == 1)
        #expect(gate.decision == .allowed)
    }

    // MARK: When it asks

    @Test func theWorkerIsAskedAtMostOncePerTenMinutes() async {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [lifted, lifted, lifted])
        let gate = viewModel(repository)

        await gate.refreshIfDue()
        #expect(repository.refreshCount == 1, "the first call asks")

        clock.move(byMinutes: 9)
        await gate.refreshIfDue()
        #expect(repository.refreshCount == 1, "9 minutes after the first it does not")

        clock.move(byMinutes: 1)
        await gate.refreshIfDue()
        #expect(repository.refreshCount == 2, "10 minutes after the first it does")
    }

    /// RF3: a device clock moved back must not hold the next refresh for hours.
    @Test func aClockMovedBackAnHourDoesNotStallTheNextRefresh() async throws {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [lifted, lifted])
        let gate = viewModel(repository)
        await gate.refreshIfDue()
        try #require(repository.refreshCount == 1)

        clock.move(byMinutes: -60)
        await gate.refreshIfDue()

        #expect(repository.refreshCount == 2)
    }

    /// A call while the first is still waiting for the Worker does not ask again, even when ten minutes have passed
    /// since the first one started (so it is the "one at a time" rule that holds it, not the wait).
    @Test func twoCallsWhileTheFirstIsHeldAskOnce() async throws {
        let repository = FakeAppConfigRepository(cached: nil, refreshResults: [armed, armed], holdsRefreshes: true)
        let gate = viewModel(repository)

        let first = Task { await gate.refreshIfDue() }
        for _ in 0..<100 where repository.refreshCount == 0 {
            await Task.yield()
        }
        try #require(repository.refreshCount == 1, "the first call is waiting for its answer")

        // The second call is a task of its own, so that a gate that did ask again (and is held too) fails this test
        // instead of waiting for a release that comes later in it.
        clock.move(byMinutes: 11)
        let second = Task { await gate.refreshIfDue() }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(repository.refreshCount == 1, "a call while one is out does not ask again")

        repository.releaseHeldRefreshes()
        await first.value
        await second.value
        #expect(repository.refreshCount == 1)
        #expect(gate.decision == .required(updateURL: appStore))
    }
}
