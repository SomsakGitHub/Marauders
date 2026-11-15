//
//  RetryingHTTPClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

private nonisolated final class ScriptedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<Int, URLError>]
    private var count = 0
    var calls: Int { lock.withLock { count } }

    nonisolated init(_ script: [Result<Int, URLError>]) { self.script = script }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        let next: Result<Int, URLError> = lock.withLock {
            count += 1
            return script.isEmpty ? .success(200) : script.removeFirst()
        }
        return HTTPClientResponse(data: Data(), statusCode: try next.get())
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        try await data(request)
    }
}

@MainActor
struct RetryingHTTPClientTests {
    private static func request(_ method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.test/v1/x")!)
        request.httpMethod = method
        return request
    }

    private static func client(_ base: ScriptedHTTPClient, attempts: Int = 3) -> RetryingHTTPClient {
        RetryingHTTPClient(base: base, maxAttempts: attempts, delayNanoseconds: { _ in 0 })
    }

    @Test func aGetIsRepeatedAfterATransientURLError() async throws {
        let base = ScriptedHTTPClient([.failure(URLError(.timedOut)), .success(200)])
        let response = try await Self.client(base).data(Self.request())
        #expect(response.statusCode == 200)
        #expect(base.calls == 2)
    }

    @Test func aGetIsRepeatedAfter503ButNotAfter404() async throws {
        let flaky = ScriptedHTTPClient([.success(503), .success(200)])
        #expect(try await Self.client(flaky).data(Self.request()).statusCode == 200)
        #expect(flaky.calls == 2)

        let missing = ScriptedHTTPClient([.success(404), .success(200)])
        #expect(try await Self.client(missing).data(Self.request()).statusCode == 404)
        #expect(missing.calls == 1)
    }

    @Test func aRejectedSessionIsNeverRepeated() async throws {
        let base = ScriptedHTTPClient([.success(401), .success(200)])
        #expect(try await Self.client(base).data(Self.request()).statusCode == 401)
        #expect(base.calls == 1)
    }

    @Test func theLastAnswerComesBackWhenEveryTryFails() async throws {
        let base = ScriptedHTTPClient([.success(503), .success(503), .success(502), .success(200)])
        #expect(try await Self.client(base).data(Self.request()).statusCode == 502)
        #expect(base.calls == 3)

        let offline = ScriptedHTTPClient(Array(repeating: .failure(URLError(.notConnectedToInternet)), count: 5))
        await #expect(throws: URLError.self) { try await Self.client(offline).data(Self.request()) }
        #expect(offline.calls == 3)
    }

    @Test func aNonTransientErrorAndACancellationGoBackAtOnce() async throws {
        let bad = ScriptedHTTPClient([.failure(URLError(.badURL)), .success(200)])
        await #expect(throws: URLError.self) { try await Self.client(bad).data(Self.request()) }
        #expect(bad.calls == 1)

        let cancelled = ScriptedHTTPClient([.failure(URLError(.cancelled)), .success(200)])
        await #expect(throws: URLError.self) { try await Self.client(cancelled).data(Self.request()) }
        #expect(cancelled.calls == 1)
    }

    @Test func writesAndUploadsAreNeverRepeated() async throws {
        let post = ScriptedHTTPClient([.success(503), .success(200)])
        #expect(try await Self.client(post).data(Self.request("POST")).statusCode == 503)
        #expect(post.calls == 1)

        let upload = ScriptedHTTPClient([.success(503), .success(200)])
        #expect(try await Self.client(upload).upload(Self.request("POST"), multipart: []).statusCode == 503)
        #expect(upload.calls == 1)
    }
}
