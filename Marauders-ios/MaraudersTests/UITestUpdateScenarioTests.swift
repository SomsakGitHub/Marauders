import Foundation
import Testing

@testable import Marauders

/// The gate as the UI tests drive it (docs/adr/012-force-update.md): a launch argument next to `UITEST` picks what the
/// gate hears from the Worker, and each case starts and ends the way the UI tests that use it assume. The two "after
/// refresh" cases are how a UI test proves that the window swaps by itself while the app runs.
@MainActor
struct UITestUpdateScenarioTests {
    private let screenLink = URL(string: "https://apps.apple.com/app/id0")!

    /// The gate the composition builds under `UITEST`: build 2, which is below the scenarios' minimum of 3, and not a
    /// debug build, so that no exemption hides the screen. No wait for the fresh answer, so the test does not wait.
    private func gate(_ scenario: UITestUpdateScenario) -> UpdateGateViewModel {
        UpdateGateViewModel(
            check: CheckUpdateRequirementUseCase(
                repository: UITestAppConfigRepository(scenario: scenario, refreshDelay: .zero),
                currentBuild: 2, isDebugBuild: false))
    }

    // MARK: The arguments

    @Test func theArgumentsPickTheScenario() {
        #expect(UITestUpdateScenario(arguments: ["UITEST"]) == .open)
        #expect(UITestUpdateScenario(arguments: ["UITEST", "UITEST_UPDATE_REQUIRED"]) == .required)
        let raised = ["UITEST", "UITEST_UPDATE_REQUIRED_AFTER_REFRESH"]
        #expect(UITestUpdateScenario(arguments: raised) == .requiredAfterRefresh)
        let lifted = ["UITEST", "UITEST_UPDATE_LIFTED_AFTER_REFRESH"]
        #expect(UITestUpdateScenario(arguments: lifted) == .liftedAfterRefresh)
    }

    @Test func aScenarioArgumentCountsOnlyNextToUITest() {
        let arguments = [
            "UITEST_UPDATE_REQUIRED", "UITEST_UPDATE_REQUIRED_AFTER_REFRESH", "UITEST_UPDATE_LIFTED_AFTER_REFRESH",
        ]
        for argument in arguments {
            #expect(UITestUpdateScenario(arguments: [argument]) == .open, "\(argument) without UITEST")
        }
    }

    // MARK: What each case does

    @Test func openNeverStopsAnyone() async {
        let gate = gate(.open)
        #expect(gate.decision == .allowed)

        await gate.refreshIfDue()

        #expect(gate.decision == .allowed)
    }

    @Test func requiredStartsOnTheScreenAndStaysThere() async {
        let gate = gate(.required)
        #expect(gate.decision == .required(updateURL: screenLink))

        await gate.refreshIfDue()

        #expect(gate.decision == .required(updateURL: screenLink))
    }

    @Test func requiredAfterRefreshStartsAsTheAppAndThenShowsTheScreen() async {
        let gate = gate(.requiredAfterRefresh)
        #expect(gate.decision == .allowed, "nothing is kept, so the window starts as the app")

        await gate.refreshIfDue()

        #expect(gate.decision == .required(updateURL: screenLink))
    }

    @Test func liftedAfterRefreshStartsOnTheScreenAndThenOpens() async {
        let gate = gate(.liftedAfterRefresh)
        #expect(gate.decision == .required(updateURL: screenLink), "the screen is kept, so the window starts as it")

        await gate.refreshIfDue()

        #expect(gate.decision == .allowed)
    }

    /// The wait is what gives a UI test time to see the first state before the swap.
    @Test func theAfterRefreshCasesWaitBeforeTheAnswerComes() async {
        let repository = UITestAppConfigRepository(scenario: .requiredAfterRefresh, refreshDelay: .milliseconds(200))

        let elapsed = await ContinuousClock().measure { _ = await repository.refresh() }

        #expect(elapsed >= .milliseconds(200))
    }
}
