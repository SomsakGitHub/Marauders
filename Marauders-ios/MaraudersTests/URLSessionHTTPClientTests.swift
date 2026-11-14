//
//  URLSessionHTTPClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct URLSessionHTTPClientTests {
    private static let url = URL(string: "https://api.example.test/v1/thing")!

    // MARK: - data

    @Test func dataReturnsTheBodyAndTheStatusCode() async throws {
        let body = Data("{\"ok\":true}".utf8)
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), body)
        }
        defer { StubURLSessionFactory.reset(session) }

        let response = try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))

        #expect(response.statusCode == 200)
        #expect(response.isSuccess)
        #expect(response.data == body)
    }

    @Test func dataSendsTheRequestAsGiven() async throws {
        var captured: URLRequest?
        var capturedBody = Data()
        let session = StubURLSessionFactory.make { request in
            captured = request
            capturedBody = Self.bodyData(from: request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        var request = URLRequest(url: Self.url)
        request.httpMethod = "PUT"
        request.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("hello".utf8)
        _ = try await URLSessionHTTPClient(session: session).data(request)

        let sent = try #require(captured)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url == Self.url)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(capturedBody == Data("hello".utf8))
    }

    @Test func aStatusOutsideTwoHundredIsAnAnswerNotAnError() async throws {
        let body = Data("{\"error\":\"missing\"}".utf8)
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 404), body)
        }
        defer { StubURLSessionFactory.reset(session) }

        let response = try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))

        #expect(response.statusCode == 404)
        #expect(!response.isSuccess)
        #expect(response.data == body)
    }

    @Test func anEmptyBodyGivesEmptyData() async throws {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 204), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let response = try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))

        #expect(response.statusCode == 204)
        #expect(response.isSuccess)
        #expect(response.data.isEmpty)
    }

    @Test func aURLErrorIsRethrownUnchanged() async throws {
        let session = StubURLSessionFactory.make { _ in throw URLError(.notConnectedToInternet) }
        defer { StubURLSessionFactory.reset(session) }

        do {
            _ = try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))
            Issue.record("Expected a failure")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Expected a URLError, got \(error)")
        }
    }

    @Test func anErrorThatIsNotAURLErrorBecomesATransportError() async throws {
        let session = StubURLSessionFactory.make { _ in
            throw NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: HTTPClientError.transport("boom")) {
            try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))
        }
    }

    @Test func aResponseThatIsNotHTTPIsInvalid() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)

        await #expect(throws: HTTPClientError.invalidResponse) {
            try await URLSessionHTTPClient(session: session).data(URLRequest(url: Self.url))
        }
    }

    @Test func cancellingTheTaskFailsTheRequestAsCancelled() async throws {
        HangingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))

        let task = Task { try await client.data(URLRequest(url: Self.url)) }
        for _ in 0 ..< 500 where !HangingURLProtocol.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(HangingURLProtocol.hasStarted)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled request to fail")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected a URLError, got \(error)")
        }
    }

    // MARK: - upload

    @Test func uploadSendsAMultipartContentTypeAndKeepsTheCallersMethodAndHeaders() async throws {
        let sent = try await upload(
            [.field(name: "caption", value: "hello")],
            headers: ["Authorization": "Bearer abc"]
        )

        let contentType = sent.request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(Self.boundary(in: contentType)?.isEmpty == false)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func uploadWritesEveryPartInOrderBetweenBoundaries() async throws {
        // CR LF and two dashes inside the file must come through as plain bytes.
        let fileBytes = Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x80, 0x7F])
        let sent = try await upload([
            .field(name: "latitude", value: "13.5"),
            .field(name: "caption", value: "Sunset ☀ Bangkok"),
            .file(name: "file", filename: "clip.mp4", mimeType: "video/mp4", data: fileBytes),
        ])
        let boundary = try #require(Self.boundary(in: sent.request.value(forHTTPHeaderField: "Content-Type") ?? ""))

        var expected = Data()
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"latitude\"\r\n\r\n13.5\r\n".utf8))
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nSunset ☀ Bangkok\r\n".utf8))
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.mp4\"\r\nContent-Type: video/mp4\r\n\r\n".utf8))
        expected.append(fileBytes)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        #expect(sent.body == expected)
    }

    @Test func uploadEscapesQuotesAndLineBreaksInNames() async throws {
        let sent = try await upload([
            .file(name: "fi\"le", filename: "my \"clip\"\r\n.mp4", mimeType: "video/mp4", data: Data([1])),
        ])

        let text = String(decoding: sent.body, as: UTF8.self)
        #expect(text.contains("name=\"fi%22le\"; filename=\"my %22clip%22%0D%0A.mp4\"\r\n"))
    }

    @Test func uploadReturnsTheStatusAndBodyOfTheAnswer() async throws {
        let answer = Data("{\"error\":\"too big\"}".utf8)
        let sent = try await upload([.field(name: "a", value: "b")], status: 413, answer: answer)

        #expect(sent.response.statusCode == 413)
        #expect(!sent.response.isSuccess)
        #expect(sent.response.data == answer)
    }

    @Test func uploadRethrowsAURLErrorUnchanged() async throws {
        let session = StubURLSessionFactory.make { _ in throw URLError(.timedOut) }
        defer { StubURLSessionFactory.reset(session) }

        do {
            _ = try await URLSessionHTTPClient(session: session)
                .upload(Self.postRequest(), multipart: [.field(name: "a", value: "b")])
            Issue.record("Expected a failure")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Expected a URLError, got \(error)")
        }
    }

    @Test func uploadStreamsTheBodyFromAFileAndRemovesItAfterwards() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var filesWhileSending: [String] = []
        let session = StubURLSessionFactory.make { request in
            filesWhileSending = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        _ = try await URLSessionHTTPClient(session: session, temporaryDirectory: directory)
            .upload(Self.postRequest(), multipart: [.field(name: "a", value: "b")])

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(filesWhileSending.count == 1)
        #expect(remaining.isEmpty)
    }

    @Test func uploadRemovesItsFileWhenTheRequestFails() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = StubURLSessionFactory.make { _ in throw URLError(.networkConnectionLost) }
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: URLError.self) {
            try await URLSessionHTTPClient(session: session, temporaryDirectory: directory)
                .upload(Self.postRequest(), multipart: [.field(name: "a", value: "b")])
        }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty)
    }

    @Test func uploadFailsAsATransportErrorWhenTheBodyCannotBeWritten() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-folder-\(UUID().uuidString)", isDirectory: true)
        let session = StubURLSessionFactory.make { request in
            Issue.record("The request must not go out without a body")
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        do {
            _ = try await URLSessionHTTPClient(session: session, temporaryDirectory: missing)
                .upload(Self.postRequest(), multipart: [.field(name: "a", value: "b")])
            Issue.record("Expected a failure")
        } catch let error as HTTPClientError {
            guard case .transport = error else {
                Issue.record("Expected a transport error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected an HTTPClientError, got \(error)")
        }
    }

    @Test func uploadSendsALargeFileWithoutLosingBytes() async throws {
        let bytes = Data((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let sent = try await upload([.file(name: "file", filename: "big.mp4", mimeType: "video/mp4", data: bytes)])
        let boundary = try #require(Self.boundary(in: sent.request.value(forHTTPHeaderField: "Content-Type") ?? ""))

        let head = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.mp4\"\r\nContent-Type: video/mp4\r\n\r\n".utf8)
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)
        #expect(sent.body.count == head.count + bytes.count + tail.count)
        #expect(sent.body.prefix(head.count) == head)
        #expect(sent.body.subdata(in: head.count ..< head.count + bytes.count) == bytes)
        #expect(sent.body.suffix(tail.count) == tail)
    }
}

// MARK: - helpers

private extension URLSessionHTTPClientTests {
    /// Uploads `parts` through a stubbed session and returns the answer plus what reached the wire.
    func upload(
        _ parts: [HTTPMultipartPart],
        headers: [String: String] = [:],
        status: Int = 201,
        answer: Data = Data()
    ) async throws -> (response: HTTPClientResponse, request: URLRequest, body: Data) {
        var sentRequest: URLRequest?
        var sentBody = Data()
        let session = StubURLSessionFactory.make { request in
            sentRequest = request
            sentBody = Self.bodyData(from: request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), answer)
        }
        defer { StubURLSessionFactory.reset(session) }

        var request = Self.postRequest()
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await URLSessionHTTPClient(session: session).upload(request, multipart: parts)
        return (response, try #require(sentRequest), sentBody)
    }

    static func postRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("url-session-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func boundary(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        return String(contentType[range.upperBound...])
    }

    nonisolated static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Answers with a response that is not an `HTTPURLResponse`.
private final class NonHTTPResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 2, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Takes a request and never answers, so a test can cancel it while it is in flight.
private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false

    static func reset() {
        lock.lock()
        started = false
        lock.unlock()
    }

    static var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.started = true
        Self.lock.unlock()
    }

    override func stopLoading() {}
}
