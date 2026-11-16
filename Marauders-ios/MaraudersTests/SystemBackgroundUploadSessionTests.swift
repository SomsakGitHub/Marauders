//
//  SystemBackgroundUploadSessionTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The real session behind `BackgroundUploadSession`: its configuration, how it tells the end of a task, which tasks it
/// listens to, what it keeps for a reader that comes late, and, over a loopback socket, the events of a real
/// background session.
///
/// Every session a test makes is invalidated when the test ends: a session keeps its delegate alive until then.
struct SystemBackgroundUploadSessionTests {
    /// Upper case on purpose: the task's description is the id in lower case.
    private static let recordID = UUID(uuidString: "0F3A9C2E-7B41-4D58-9E16-2A8C5D7B1E90")!
    private static let token = UploaderKit.validToken()
    private static let apiURL = URL(string: "https://api.example.test/v1/videos")!

    // MARK: The configuration

    @Test func theConfigurationHasTheSpecsFlags() {
        let configuration = SystemBackgroundUploadSession.makeConfiguration()

        #expect(SystemBackgroundUploadSession.identifier == "com.somsak.Marauders.upload")
        #expect(configuration.identifier == "com.somsak.Marauders.upload")
        #expect(!configuration.isDiscretionary)
        #expect(configuration.allowsCellularAccess)
        #expect(configuration.allowsExpensiveNetworkAccess)
        #expect(configuration.allowsConstrainedNetworkAccess)
        #expect(configuration.timeoutIntervalForResource == 24 * 60 * 60)
        #expect(configuration.sessionSendsLaunchEvents)
        #expect(SystemBackgroundUploadSession.makeConfiguration(identifier: "another").identifier == "another")
    }

    // MARK: How the end of a task is told

    /// How a task ended, and what the event about it must say.
    struct Ending: Sendable, CustomTestStringConvertible {
        let name: String
        /// The status of the response the task held; nil for a task with no response.
        let status: Int?
        let error: (any Error)?
        let failure: TransportFailure?

        var testDescription: String { name }
    }

    private static func connection(_ code: URLError.Code) -> TransportFailure {
        .connection(URLError(code).localizedDescription)
    }

    private static let endings: [Ending] = [
        Ending(name: "a 201 answer", status: 201, error: nil, failure: nil),
        Ending(name: "no answer and no error", status: nil, error: nil, failure: nil),
        Ending(name: "cancelled", status: nil, error: URLError(.cancelled), failure: .cancelled),
        Ending(
            name: "offline", status: nil, error: URLError(.notConnectedToInternet),
            failure: connection(.notConnectedToInternet)),
        Ending(
            name: "another URLError", status: nil, error: URLError(.badServerResponse),
            failure: .other(URLError(.badServerResponse).localizedDescription)),
        Ending(
            name: "an error that is no URLError", status: nil,
            error: NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"]),
            failure: .other("boom")),
        // A status wins over a failure: a task can hold the Worker's 200 and still end cancelled or with a lost
        // connection, and the clip exists. The event carries both; the uploader reads the status.
        Ending(name: "a 200 and then cancelled", status: 200, error: URLError(.cancelled), failure: .cancelled),
        Ending(
            name: "a 200 and then a lost connection", status: 200, error: URLError(.networkConnectionLost),
            failure: connection(.networkConnectionLost)),
    ]

    @Test(arguments: endings)
    func aCompletionMapsItsStatusItsFailureAndTheTokenOfItsRequest(_ ending: Ending) throws {
        let response = ending.status.flatMap {
            HTTPURLResponse(url: Self.apiURL, statusCode: $0, httpVersion: "HTTP/1.1", headerFields: nil)
        }
        var request = URLRequest(url: Self.apiURL)
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")

        let event = SystemBackgroundUploadSession.completionEvent(
            recordID: Self.recordID, response: response, error: ending.error, originalRequest: request)

        #expect(
            event
                == .completed(
                    recordID: Self.recordID, statusCode: ending.status, failure: ending.failure, accessToken: Self.token
                )
        )
    }

    /// The failures that mean the network failed, not the upload: the Worker may well be fine.
    private static let connectionCodes: [URLError.Code] = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut, .dnsLookupFailed, .cannotFindHost,
        .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed,
    ]

    @Test(arguments: connectionCodes)
    func aConnectionClassErrorIsAConnectionFailure(_ code: URLError.Code) {
        let error = URLError(code)

        let event = SystemBackgroundUploadSession.completionEvent(
            recordID: Self.recordID, response: nil, error: error, originalRequest: nil)

        #expect(
            event
                == .completed(
                    recordID: Self.recordID, statusCode: nil, failure: .connection(error.localizedDescription),
                    accessToken: nil))
    }

    @Test(arguments: [URLError.Code.badURL, .secureConnectionFailed, .badServerResponse, .resourceUnavailable])
    func anyOtherErrorIsAnOtherFailure(_ code: URLError.Code) {
        let error = URLError(code)

        let event = SystemBackgroundUploadSession.completionEvent(
            recordID: Self.recordID, response: nil, error: error, originalRequest: nil)

        #expect(
            event
                == .completed(
                    recordID: Self.recordID, statusCode: nil, failure: .other(error.localizedDescription),
                    accessToken: nil))
    }

    @Test func aRequestWithoutABearerGivesNoToken() {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("Basic abc", forHTTPHeaderField: "Authorization")

        for original in [nil, URLRequest(url: Self.apiURL), request] {
            let event = SystemBackgroundUploadSession.completionEvent(
                recordID: Self.recordID, response: nil, error: nil, originalRequest: original)

            #expect(event == .completed(recordID: Self.recordID, statusCode: nil, failure: nil, accessToken: nil))
        }
    }

    // MARK: What the delegate tells

    @Test(.timeLimit(.minutes(1)))
    func theDelegateTellsProgressTheAnswerAndTheEndOfARecordsTaskInOrder() async throws {
        let sut = SystemBackgroundUploadSession(configuration: .ephemeral)
        defer { sut.session.invalidateAndCancel() }
        let other = URLSession(configuration: .ephemeral)
        defer { other.invalidateAndCancel() }
        var request = URLRequest(url: Self.apiURL)
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        let task = other.dataTask(with: request)
        task.taskDescription = Self.recordID.uuidString.lowercased()

        sut.urlSession(other, task: task, didSendBodyData: 40, totalBytesSent: 40, totalBytesExpectedToSend: 100)
        sut.urlSession(
            other, task: task, didSendBodyData: 60, totalBytesSent: 100,
            totalBytesExpectedToSend: NSURLSessionTransferSizeUnknown)
        sut.urlSession(other, dataTask: task, didReceive: Data(#"{"item""#.utf8))
        sut.urlSession(other, dataTask: task, didReceive: Data(":{}}".utf8))
        sut.urlSession(other, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        sut.urlSessionDidFinishEvents(forBackgroundURLSession: other)

        let seen = await Self.read(sut.events) { $0 == .eventsFinished }
        #expect(
            seen == [
                .sentBytes(recordID: Self.recordID, sent: 40, expected: 100),
                .sentBytes(recordID: Self.recordID, sent: 100, expected: -1),
                .receivedBody(recordID: Self.recordID, data: Data(#"{"item""#.utf8)),
                .receivedBody(recordID: Self.recordID, data: Data(":{}}".utf8)),
                .completed(
                    recordID: Self.recordID, statusCode: nil, failure: Self.connection(.networkConnectionLost),
                    accessToken: Self.token),
                .eventsFinished,
            ])
    }

    @Test(.timeLimit(.minutes(1))) func aTaskWithoutOurRecordIdIsIgnored() async throws {
        let sut = SystemBackgroundUploadSession(configuration: .ephemeral)
        defer { sut.session.invalidateAndCancel() }
        let other = URLSession(configuration: .ephemeral)
        defer { other.invalidateAndCancel() }

        // Three tasks that are not ours: none with a description, an empty one and one that is no record id. Nothing
        // they do is told.
        for description in [nil, "", "not-a-record-id"] as [String?] {
            let stranger = other.dataTask(with: Self.apiURL)
            stranger.taskDescription = description
            sut.urlSession(other, task: stranger, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: 2)
            sut.urlSession(other, dataTask: stranger, didReceive: Data("{}".utf8))
            sut.urlSession(other, task: stranger, didCompleteWithError: URLError(.cancelled))
        }
        // One that is ours, then the system's marker, which belongs to the session and names no task.
        let ours = other.dataTask(with: Self.apiURL)
        ours.taskDescription = Self.recordID.uuidString
        sut.urlSession(other, task: ours, didSendBodyData: 5, totalBytesSent: 5, totalBytesExpectedToSend: 10)
        sut.urlSessionDidFinishEvents(forBackgroundURLSession: other)

        let seen = await Self.read(sut.events) { $0 == .eventsFinished }
        #expect(seen == [.sentBytes(recordID: Self.recordID, sent: 5, expected: 10), .eventsFinished])
    }

    @Test(.timeLimit(.minutes(1))) func eventsThatComeBeforeAnyoneReadsAreKeptInOrder() async throws {
        let sut = SystemBackgroundUploadSession(configuration: .ephemeral)
        defer { sut.session.invalidateAndCancel() }
        let other = URLSession(configuration: .ephemeral)
        defer { other.invalidateAndCancel() }
        let task = other.dataTask(with: Self.apiURL)
        task.taskDescription = Self.recordID.uuidString.lowercased()

        // What the system hands a recreated session at once, long before the uploader reads the stream.
        for sent in 1...500 {
            sut.urlSession(
                other, task: task, didSendBodyData: 1, totalBytesSent: Int64(sent), totalBytesExpectedToSend: 500)
        }
        sut.urlSessionDidFinishEvents(forBackgroundURLSession: other)

        let seen = await Self.read(sut.events) { $0 == .eventsFinished }
        let progress = (1...500).map {
            UploadSessionEvent.sentBytes(recordID: Self.recordID, sent: Int64($0), expected: 500)
        }
        #expect(seen == progress + [.eventsFinished])
    }

    // MARK: The tasks of the session

    @Test(.timeLimit(.minutes(1))) func submitTagsTheTaskWithItsRecordAndTheByteHints() async throws {
        let sut = SystemBackgroundUploadSession(configuration: Self.neverAnsweringConfiguration())
        defer { sut.session.invalidateAndCancel() }
        let bodyFile = try Self.writeBody(byteCount: 2_048)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        sut.submit(Self.request(to: Self.apiURL), bodyFile: bodyFile, recordID: Self.recordID, expectedBytes: 2_048)

        let tasks = await sut.session.allTasks
        let task = try #require(tasks.first)
        #expect(tasks.count == 1)
        #expect(task is URLSessionUploadTask)
        #expect(task.state == .running)
        #expect(task.taskDescription == "0f3a9c2e-7b41-4d58-9e16-2a8c5d7b1e90")
        #expect(task.countOfBytesClientExpectsToSend == 2_048 + 1_024)
        #expect(task.countOfBytesClientExpectsToReceive == 65_536)
        #expect(task.originalRequest?.bearerToken == Self.token)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingRecordIDsListTheTasksOfRecordsAndCancelEndsOnlyTheTaskOfItsRecord() async throws {
        let sut = SystemBackgroundUploadSession(configuration: Self.neverAnsweringConfiguration())
        defer { sut.session.invalidateAndCancel() }
        let bodyFile = try Self.writeBody(byteCount: 2_048)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let request = Self.request(to: Self.apiURL)
        let first = UUID()
        let second = UUID()
        sut.submit(request, bodyFile: bodyFile, recordID: first, expectedBytes: 2_048)
        sut.submit(request, bodyFile: bodyFile, recordID: second, expectedBytes: 2_048)
        // A task that carries no record id is no one's: not listed, and not touched by a cancel.
        let stranger = sut.session.uploadTask(with: request, fromFile: bodyFile)
        stranger.taskDescription = "not-a-record-id"
        stranger.resume()

        #expect(await sut.pendingRecordIDs() == [first, second])

        await sut.cancel(recordID: first)
        let seen = await Self.read(sut.events) {
            if case .completed(first, _, _, _) = $0 { true } else { false }
        }
        #expect(
            seen == [.completed(recordID: first, statusCode: nil, failure: .cancelled, accessToken: Self.token)])
        // The ended task leaves the list once its end is told; give the session a moment to drop it.
        var pending = await sut.pendingRecordIDs()
        for _ in 0..<200 where pending != [second] {
            try await Task.sleep(for: .milliseconds(10))
            pending = await sut.pendingRecordIDs()
        }
        #expect(pending == [second])
        #expect(stranger.state == .running)
    }

    // MARK: A real background session

    @Test(.timeLimit(.minutes(1)))
    func aRealBackgroundSessionReportsProgressAndTheAnswerOverLoopback() async throws {
        let answer = UploaderKit.answer()
        let server = LoopbackHTTPServer(status: 201, body: answer)
        let url = try await server.start()
        defer { server.stop() }
        let bodyFile = try Self.writeBody(byteCount: 3_000_000)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        // A fresh identifier for every run: two background sessions with one identifier in one process misbehave.
        let identifier = "\(SystemBackgroundUploadSession.identifier).test.\(UUID().uuidString)"
        let sut = SystemBackgroundUploadSession(
            configuration: SystemBackgroundUploadSession.makeConfiguration(identifier: identifier))
        defer { sut.session.invalidateAndCancel() }

        sut.submit(Self.request(to: url), bodyFile: bodyFile, recordID: Self.recordID, expectedBytes: 3_000_000)

        // With the app in the foreground the system never sends its "finished events" marker, and the response
        // callback is never called for an upload task: the wait ends at the completion.
        let seen = await Self.read(sut.events) {
            if case .completed = $0 { true } else { false }
        }

        var sentCounts: [Int64] = []
        var answerBytes = Data()
        for event in seen.dropLast() {
            switch event {
            case .sentBytes(let id, let sent, let expected):
                #expect(id == Self.recordID)
                #expect(expected == 3_000_000)
                sentCounts.append(sent)
            case .receivedBody(let id, let data):
                #expect(id == Self.recordID)
                answerBytes.append(data)
            case .completed:
                Issue.record("Only the last event may be a completion")
            case .eventsFinished:
                break
            }
        }
        #expect(!sentCounts.isEmpty)
        #expect(sentCounts == sentCounts.sorted())
        #expect(sentCounts.last == 3_000_000)
        #expect(answerBytes == answer)
        #expect(
            seen.last == .completed(recordID: Self.recordID, statusCode: 201, failure: nil, accessToken: Self.token))
        #expect(server.receivedBodyByteCounts == [3_000_000])
    }

    // MARK: Helpers

    /// Reads `events` until one satisfies `isLast`, and returns everything read, that event included.
    private static func read(
        _ events: AsyncStream<UploadSessionEvent>, through isLast: (UploadSessionEvent) -> Bool
    ) async -> [UploadSessionEvent] {
        var seen: [UploadSessionEvent] = []
        for await event in events {
            seen.append(event)
            if isLast(event) { break }
        }
        return seen
    }

    /// A POST with the bearer, as the uploader builds one.
    private static func request(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=test", forHTTPHeaderField: "Content-Type")
        request.setValue(recordID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    private static func writeBody(byteCount: Int) throws -> URL {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "system-session-\(UUID().uuidString).multipart")
        try Data(repeating: 0xAB, count: byteCount).write(to: file)
        return file
    }

    /// An ephemeral configuration whose tasks never get an answer: a task stays running until it is cancelled.
    private static func neverAnsweringConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverAnsweringURLProtocol.self]
        return configuration
    }
}

/// A protocol that never answers, so that a task keeps running.
private final class NeverAnsweringURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
