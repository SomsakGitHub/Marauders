//
//  BackgroundUploadSession.swift
//  Marauders
//

import Foundation

/// How a task of the background session failed, when it ended without an answer from the Worker.
nonisolated enum TransportFailure: Equatable, Sendable {
    /// The task was cancelled: by the app, or by the system.
    case cancelled
    /// The network failed; the text is the transport's own.
    case connection(String)
    /// Any other failure; the text is the transport's own.
    case other(String)
}

/// What the background session reports about the task of a pending upload, in the order it happened.
nonisolated enum UploadSessionEvent: Equatable, Sendable {
    /// `sent` of `expected` bytes of the body are out. `expected` is 0 or less when the session does not know it.
    case sentBytes(recordID: UUID, sent: Int64, expected: Int64)
    /// A piece of the Worker's answer.
    case receivedBody(recordID: UUID, data: Data)
    /// The task ended. A status code wins over a failure: the Worker answered. `accessToken` is the bearer the task
    /// carried.
    case completed(recordID: UUID, statusCode: Int?, failure: TransportFailure?, accessToken: String?)
    /// The system has handed over every event it held for the app.
    case eventsFinished
}

/// The background `URLSession` the uploader sends a body with, behind a seam so the uploader can be tested without
/// one. Its tasks outlive the app; their record id travels with them.
nonisolated protocol BackgroundUploadSession: Sendable {
    /// Every event of every task, in order. Read once.
    var events: AsyncStream<UploadSessionEvent> { get }

    /// Hands the body file to the system to send with `request`, under `recordID`. Returns at once.
    func submit(_ request: URLRequest, bodyFile: URL, recordID: UUID, expectedBytes: Int64)

    /// The records whose task the system still holds.
    func pendingRecordIDs() async -> Set<UUID>

    /// Cancels the task of `recordID`, if there is one.
    func cancel(recordID: UUID) async
}
