//
//  UITestAppConfigRepository.swift
//  Marauders
//

import Foundation

/// The force-update gate's answers for UI tests, with no transport at all. The scenario (a launch argument, see
/// `UITestUpdateScenario`) says what is kept at launch and what the fresh answer will be: build 3 is the oldest that
/// may run, or no gate at all. The two "after refresh" scenarios make the fresh answer wait, so that a UI test can see
/// the window as it starts before it swaps.
struct UITestAppConfigRepository: AppConfigRepository {
    private static let required = AppConfig(minimumBuild: 3, updateURL: URL(string: "https://apps.apple.com/app/id0"))
    /// What the console holds when there is no gate: a minimum of 0 and no link.
    private static let noGate = AppConfig(minimumBuild: 0, updateURL: nil)

    private let scenario: UITestUpdateScenario
    private let refreshDelay: Duration

    /// - Parameter refreshDelay: How long the "after refresh" scenarios wait before the fresh answer comes. It must
    ///   outlast the time a UI test needs to find the first state; the unit tests pass zero.
    init(scenario: UITestUpdateScenario, refreshDelay: Duration = .seconds(10)) {
        self.scenario = scenario
        self.refreshDelay = refreshDelay
    }

    func cached() -> AppConfig? {
        switch scenario {
        case .open, .requiredAfterRefresh:
            nil
        case .required, .liftedAfterRefresh:
            Self.required
        }
    }

    func refresh() async -> AppConfig? {
        switch scenario {
        case .open:
            return nil
        case .required:
            return Self.required
        case .requiredAfterRefresh:
            return await answer(Self.required)
        case .liftedAfterRefresh:
            return await answer(Self.noGate)
        }
    }

    /// The answer after the wait; nil when the wait is cancelled, which is what the real repository does too (a
    /// cancelled ask leaves what is kept as it was).
    private func answer(_ config: AppConfig) async -> AppConfig? {
        do {
            try await Task.sleep(for: refreshDelay)
        } catch {
            return nil
        }
        return config
    }
}
