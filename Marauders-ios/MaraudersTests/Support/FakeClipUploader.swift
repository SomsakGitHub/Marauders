//
//  FakeClipUploader.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// A `ClipUploading` for the code that sits above the uploader (the use cases, the Upload tab, sign out): it notes what
/// it is asked, publishes the snapshots a test hands it with `emit`, and can refuse a start, hold a start or a discard
/// at a gate, and tell a test the moment a discard arrives (so the test can look at the world as it was then).
///
/// nonisolated: the code under test calls it from its own tasks while the test reads the counts, which the lock makes
/// safe.
nonisolated final class FakeClipUploader: ClipUploading, @unchecked Sendable {
    private struct State {
        var current: UploadSnapshot
        var observers: [AsyncStream<UploadSnapshot>.Continuation] = []
        var startError: (any Error)?
        var startGate: SignOutGate?
        var discardGate: SignOutGate?
        var onDiscard: (@Sendable () -> Void)?
        var started: [ClipUploadRequest] = []
        var retries = 0
        var discards = 0
        var reconciles = 0
    }

    private let lock = NSLock()
    private var state: State

    /// `snapshot` is where things stand when the first observer arrives.
    init(snapshot: UploadSnapshot = .idle) {
        state = State(current: snapshot)
    }

    /// Thrown by `start` after its gate, if it has one, lets it through. Nil: the start is accepted.
    var startError: (any Error)? {
        get { lock.withLock { state.startError } }
        set { lock.withLock { state.startError = newValue } }
    }

    /// A start waits here, after it is noted in `started`, and ignores cancellation while it does.
    var startGate: SignOutGate? {
        get { lock.withLock { state.startGate } }
        set { lock.withLock { state.startGate = newValue } }
    }

    /// A discard waits here, after it is counted and `onDiscard` has run, and ignores cancellation while it does.
    var discardGate: SignOutGate? {
        get { lock.withLock { state.discardGate } }
        set { lock.withLock { state.discardGate = newValue } }
    }

    /// Runs when a discard arrives, before it waits at its gate.
    var onDiscard: (@Sendable () -> Void)? {
        get { lock.withLock { state.onDiscard } }
        set { lock.withLock { state.onDiscard = newValue } }
    }

    /// Every request `start` was given, in order, whether or not it was refused.
    var started: [ClipUploadRequest] { lock.withLock { state.started } }
    var retries: Int { lock.withLock { state.retries } }
    var discards: Int { lock.withLock { state.discards } }
    var reconciles: Int { lock.withLock { state.reconciles } }

    /// Makes `snapshot` the current one and tells every observer.
    func emit(_ snapshot: UploadSnapshot) {
        lock.withLock {
            state.current = snapshot
            for observer in state.observers { observer.yield(snapshot) }
        }
    }

    func start(_ request: ClipUploadRequest) async throws {
        let gate = lock.withLock {
            state.started.append(request)
            return state.startGate
        }
        await gate?.wait()
        if let error = startError { throw error }
    }

    /// The current snapshot first, then every `emit` after it. The stream stays open until its reader stops.
    func snapshots() async -> AsyncStream<UploadSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: UploadSnapshot.self)
        lock.withLock {
            continuation.yield(state.current)
            state.observers.append(continuation)
        }
        return stream
    }

    func retry() async {
        lock.withLock { state.retries += 1 }
    }

    func discard() async {
        let (hook, gate) = lock.withLock {
            state.discards += 1
            return (state.onDiscard, state.discardGate)
        }
        hook?()
        await gate?.wait()
    }

    func reconcile() async {
        lock.withLock { state.reconciles += 1 }
    }
}
