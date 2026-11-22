//
//  FakeRemoteConfigSource.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// A `RemoteConfigSource` for the repository above it: the first call to `fetch()` answers `results[0]`, the second
/// `results[1]`, and so on, and the last one answers every call after that (nil when there are none). It counts the
/// calls. With `cancelsWhileFetching` the call cancels the task it runs in before it answers, which is what a refresh
/// that is cancelled while it waits looks like to the repository.
///
/// A class, not an actor, like `FakeAppConfigRepository`: everything runs on the main actor, which is why it needs no
/// lock.
final class FakeRemoteConfigSource: RemoteConfigSource, @unchecked Sendable {
    private let results: [RemoteConfigValues?]
    private let cancelsWhileFetching: Bool

    /// How many times `fetch()` was called.
    private(set) var fetchCount = 0

    init(_ results: [RemoteConfigValues?], cancelsWhileFetching: Bool = false) {
        self.results = results
        self.cancelsWhileFetching = cancelsWhileFetching
    }

    func fetch() async -> RemoteConfigValues? {
        let call = fetchCount
        fetchCount += 1
        if cancelsWhileFetching {
            withUnsafeCurrentTask { (task: UnsafeCurrentTask?) -> Void in task?.cancel() }
        }
        guard !results.isEmpty else {
            return nil
        }
        return results[min(call, results.count - 1)]
    }
}
