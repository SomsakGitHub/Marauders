//
//  SystemBackgroundUploadSession.swift
//  Marauders
//

import Foundation

/// The system's background `URLSession`, behind `BackgroundUploadSession`: the system sends a staged body file for the
/// app, goes on when the app is suspended or ended, and relaunches the app to tell it how the upload ended.
///
/// One instance per process, created before any view exists: a recreated session is found by its identifier, and the
/// system hands it the events it held at once. The stream those events go into is made first and buffers without a
/// limit, so none is lost between the session's creation and the moment the uploader starts reading.
///
/// A task belongs to an upload when its `taskDescription` is that upload's record id; a task with any other
/// description is ignored, in the listing and in every event. Delegate calls arrive on one serial queue, so the events
/// keep the order the system gave them.
///
/// It logs nothing: `AppLog` is main-actor, and the delegate calls are not.
nonisolated final class SystemBackgroundUploadSession: NSObject, BackgroundUploadSession, URLSessionDataDelegate,
    @unchecked Sendable
{
    /// The name the system finds the session by when it relaunches the app.
    static let identifier = "com.somsak.Marauders.upload"

    /// How much more than the body the system is told to expect to send (the request's own head).
    private static let headSlackBytes: Int64 = 1_024
    /// How much of the Worker's answer the system is told to expect: all the app keeps of it.
    private static let answerBytes: Int64 = 65_536

    /// The failures that say the network failed rather than the upload.
    private static let connectionCodes: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut, .dnsLookupFailed, .cannotFindHost,
        .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed,
    ]

    /// The configuration of the upload session: it starts at once, over any network, and may take a day.
    static func makeConfiguration(
        identifier: String = SystemBackgroundUploadSession.identifier
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }

    /// Every event of every task, in order. Read once.
    let events: AsyncStream<UploadSessionEvent>
    private let continuation: AsyncStream<UploadSessionEvent>.Continuation
    /// Set once, by `init`, as soon as the delegate (this object) exists; nothing reads it before `init` returns. The
    /// system keeps the session, and with it this object, alive until the session is invalidated: a test that makes
    /// one invalidates it through this property.
    private(set) var session: URLSession!

    init(configuration: URLSessionConfiguration = SystemBackgroundUploadSession.makeConfiguration()) {
        // The stream comes before the session: the system may deliver events the moment the session exists.
        (events, continuation) = AsyncStream.makeStream(of: UploadSessionEvent.self)
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: BackgroundUploadSession

    func submit(_ request: URLRequest, bodyFile: URL, recordID: UUID, expectedBytes: Int64) {
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = recordID.uuidString.lowercased()
        task.countOfBytesClientExpectsToSend = expectedBytes + Self.headSlackBytes
        task.countOfBytesClientExpectsToReceive = Self.answerBytes
        task.resume()
    }

    /// Every task of a record the session lists, whatever its state. After a relaunch the system lists a task it has
    /// finished but not yet told the app about, so a listed task is not a running one.
    func pendingRecordIDs() async -> Set<UUID> {
        Set(await session.allTasks.compactMap(Self.recordID(of:)))
    }

    func cancel(recordID: UUID) async {
        for task in await session.allTasks where Self.recordID(of: task) == recordID {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let recordID = Self.recordID(of: task) else { return }
        continuation.yield(.sentBytes(recordID: recordID, sent: totalBytesSent, expected: totalBytesExpectedToSend))
    }

    /// The Worker's answer. The response callback is never called for an upload task, so the status is read from the
    /// task when it ends.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let recordID = Self.recordID(of: dataTask) else { return }
        continuation.yield(.receivedBody(recordID: recordID, data: data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let recordID = Self.recordID(of: task) else { return }
        continuation.yield(
            Self.completionEvent(
                recordID: recordID, response: task.response, error: error, originalRequest: task.originalRequest))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.eventsFinished)
    }

    // MARK: Events

    /// How the task of `recordID` ended. The status is the response's, whenever it has one: a task can hold the
    /// Worker's 200 and still end cancelled or with a lost connection, and the event carries both. The failure comes
    /// from the error alone, and the access token is the bearer the task was sent with.
    static func completionEvent(
        recordID: UUID, response: URLResponse?, error: (any Error)?, originalRequest: URLRequest?
    ) -> UploadSessionEvent {
        .completed(
            recordID: recordID, statusCode: (response as? HTTPURLResponse)?.statusCode,
            failure: error.map(failure(of:)),
            accessToken: originalRequest?.bearerToken)
    }

    private static func failure(of error: any Error) -> TransportFailure {
        guard let urlError = error as? URLError else { return .other(error.localizedDescription) }
        if urlError.code == .cancelled { return .cancelled }
        if connectionCodes.contains(urlError.code) { return .connection(urlError.localizedDescription) }
        return .other(urlError.localizedDescription)
    }

    /// The record a task belongs to; nil for a task that is not an upload of ours.
    private static func recordID(of task: URLSessionTask) -> UUID? {
        UUID(uuidString: task.taskDescription ?? "")
    }
}
