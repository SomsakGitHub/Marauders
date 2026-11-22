//
//  CheckUpdateRequirementUseCase.swift
//  Marauders
//

import Foundation

/// Hands the kept answer and each fresh answer to the rule (`UpdateDecision.decide`) together with this build's own
/// number and kind.
struct CheckUpdateRequirementUseCase: Sendable {
    private let repository: AppConfigRepository
    private let currentBuild: Int?
    private let isDebugBuild: Bool

    init(repository: AppConfigRepository, currentBuild: Int?, isDebugBuild: Bool) {
        self.repository = repository
        self.currentBuild = currentBuild
        self.isDebugBuild = isDebugBuild
    }

    /// What the kept answer says, without waiting. `.allowed` when nothing is kept.
    func cached() -> UpdateDecision {
        UpdateDecision.decide(config: repository.cached(), currentBuild: currentBuild, isDebugBuild: isDebugBuild)
    }

    /// Asks once. Nil when that failed, meaning "keep what is shown": a failed refresh is not an answer.
    func refresh() async -> UpdateDecision? {
        guard let config = await repository.refresh() else {
            return nil
        }
        return UpdateDecision.decide(config: config, currentBuild: currentBuild, isDebugBuild: isDebugBuild)
    }
}
