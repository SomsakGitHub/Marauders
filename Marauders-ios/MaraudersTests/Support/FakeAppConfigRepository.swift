//
//  FakeAppConfigRepository.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// An `AppConfigRepository` for the code above it (the use case and the gate's view model): it hands out the kept
/// answer a test gives it, answers each `refresh()` with the next of `refreshResults` (nil once they run out), counts
/// the refreshes, and can hold them until `releaseHeldRefreshes()`.
///
/// A class, not an actor: Swift 6.4 does not let an actor conform to this MainActor-isolated protocol. Everything runs
/// on the main actor, which is why it needs no lock.
final class FakeAppConfigRepository: AppConfigRepository, @unchecked Sendable {
    private let keptConfig: AppConfig?
    private var results: [AppConfig?]
    private let holdsRefreshes: Bool
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// How many times `refresh()` was called, the held ones included.
    private(set) var refreshCount = 0

    /// - Parameters:
    ///   - cached: what `cached()` returns.
    ///   - refreshResults: what the first, second, ... call of `refresh()` returns; nil stands for a refresh that failed.
    ///   - holdsRefreshes: a `refresh()` waits, after it is counted, until `releaseHeldRefreshes()`.
    init(cached: AppConfig?, refreshResults: [AppConfig?], holdsRefreshes: Bool = false) {
        keptConfig = cached
        results = refreshResults
        self.holdsRefreshes = holdsRefreshes
    }

    func cached() -> AppConfig? {
        keptConfig
    }

    func refresh() async -> AppConfig? {
        refreshCount += 1
        let result: AppConfig? = results.isEmpty ? nil : results.removeFirst()
        if holdsRefreshes && !released {
            await withCheckedContinuation { held.append($0) }
        }
        return result
    }

    /// Lets every held `refresh()` go on, and stops holding the ones that come after.
    func releaseHeldRefreshes() {
        released = true
        let waiting = held
        held = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}
