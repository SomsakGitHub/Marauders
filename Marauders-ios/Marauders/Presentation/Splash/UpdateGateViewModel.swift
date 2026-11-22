//
//  UpdateGateViewModel.swift
//  Marauders
//

import Foundation
import Observation

/// Holds what the window shows in place of the app: the Update screen when this build is below the minimum build
/// (docs/adr/012-force-update.md), nothing otherwise.
///
/// `decision` starts from the answer the last launch kept and never waits for the network, so a build that is known to
/// be too old is stopped at once, and one that knows nothing is never blocked. `refreshIfDue()` asks for a fresh
/// answer: at most once per `minimumRefreshInterval` (measured from the start of the last ask, and restarted
/// when the device clock moves back) and never while an ask is out. A fresh answer replaces `decision`; a failed ask
/// keeps it.
///
/// Logs under `update`, once per change and without anything that identifies a person: `decision: required|allowed`.
@MainActor
@Observable
final class UpdateGateViewModel {
    private(set) var decision: UpdateDecision

    @ObservationIgnored private let check: CheckUpdateRequirementUseCase
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval
    /// When the last ask started. Nil before the first one.
    @ObservationIgnored private var lastRefreshStart: Date?
    @ObservationIgnored private var isRefreshing = false

    /// - Parameters:
    ///   - now: The clock, which a test moves.
    ///   - minimumRefreshInterval: How long after an ask started the next one may start, in seconds.
    init(
        check: CheckUpdateRequirementUseCase,
        now: @escaping () -> Date = { Date() },
        minimumRefreshInterval: TimeInterval = 600
    ) {
        self.check = check
        self.now = now
        self.minimumRefreshInterval = minimumRefreshInterval
        decision = check.cached()
        Self.log(decision)
    }

    /// Asks once unless an ask is out, or the last one started less than `minimumRefreshInterval` ago. A clock
    /// that now reads earlier than that start counts as long enough ago: it must not hold the next ask for hours.
    func refreshIfDue() async {
        guard !isRefreshing else { return }
        let started = now()
        if let last = lastRefreshStart, started >= last, started.timeIntervalSince(last) < minimumRefreshInterval {
            return
        }
        isRefreshing = true
        lastRefreshStart = started
        let fresh = await check.refresh()
        isRefreshing = false
        if let fresh, fresh != decision {
            decision = fresh
            Self.log(fresh)
        }
    }

    private static func log(_ decision: UpdateDecision) {
        switch decision {
        case .allowed:
            AppLog.info("update", "decision: allowed")
        case .required:
            AppLog.info("update", "decision: required")
        }
    }
}
