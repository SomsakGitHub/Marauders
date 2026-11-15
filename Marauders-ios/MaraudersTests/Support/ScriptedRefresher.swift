//
//  ScriptedRefresher.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// A `TokenRefreshing` that answers from a list of prepared outcomes, in order, and remembers which rejected access
/// token each question was about. Asked more often than it was scripted for, it answers `.unavailable`: a test that
/// expects the refresher to be left alone scripts nothing and checks `asked`.
///
/// nonisolated: the code under test asks from its own tasks while the test reads `asked`, which the lock makes safe.
nonisolated final class ScriptedRefresher: TokenRefreshing, @unchecked Sendable {
    /// What a question after the end of the list ends with.
    struct NothingScripted: Error {}

    private let lock = NSLock()
    private var outcomes: [TokenRefreshOutcome]
    private var rejectedTokens: [String] = []

    init(_ outcomes: TokenRefreshOutcome...) {
        self.outcomes = outcomes
    }

    /// The rejected access token of every question, in order.
    var asked: [String] { lock.withLock { rejectedTokens } }

    func refreshedAccessToken(replacing rejectedAccessToken: String) async -> TokenRefreshOutcome {
        lock.withLock {
            rejectedTokens.append(rejectedAccessToken)
            return outcomes.isEmpty ? .unavailable(NothingScripted()) : outcomes.removeFirst()
        }
    }
}
