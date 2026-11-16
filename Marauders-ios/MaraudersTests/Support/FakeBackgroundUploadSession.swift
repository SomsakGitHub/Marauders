//
//  FakeBackgroundUploadSession.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// A `BackgroundUploadSession` that sends nothing: it notes every submission and every cancel, keeps a pending set a
/// test can also set by hand, and hands the uploader the events a test gives `emit`.
///
/// A submission makes its record pending and a cancel takes it out again, as a real session's tasks come and go.
///
/// nonisolated: the uploader calls it from its own actor while the test reads what it noted, which the lock makes safe.
nonisolated final class FakeBackgroundUploadSession: BackgroundUploadSession, @unchecked Sendable {
    struct Submission: Sendable {
        let request: URLRequest
        let bodyFile: URL
        let recordID: UUID
        let expectedBytes: Int64
    }

    let events: AsyncStream<UploadSessionEvent>
    private let continuation: AsyncStream<UploadSessionEvent>.Continuation
    private let lock = NSLock()
    private var storedSubmissions: [Submission] = []
    private var storedPending: Set<UUID> = []
    private var storedCancelled: [UUID] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: UploadSessionEvent.self)
    }

    /// Every submission, in order.
    var submissions: [Submission] { lock.withLock { storedSubmissions } }

    /// The records the session says it has a task for.
    var pending: Set<UUID> {
        get { lock.withLock { storedPending } }
        set { lock.withLock { storedPending = newValue } }
    }

    /// Every record whose task the uploader cancelled, in order.
    var cancelled: [UUID] { lock.withLock { storedCancelled } }

    /// Hands `event` to whoever reads `events`.
    func emit(_ event: UploadSessionEvent) {
        continuation.yield(event)
    }

    func submit(_ request: URLRequest, bodyFile: URL, recordID: UUID, expectedBytes: Int64) {
        lock.withLock {
            storedSubmissions.append(
                Submission(request: request, bodyFile: bodyFile, recordID: recordID, expectedBytes: expectedBytes))
            storedPending.insert(recordID)
        }
    }

    func pendingRecordIDs() async -> Set<UUID> {
        pending
    }

    func cancel(recordID: UUID) async {
        lock.withLock {
            storedCancelled.append(recordID)
            storedPending.remove(recordID)
        }
    }
}
