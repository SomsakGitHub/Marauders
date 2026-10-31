//
//  RejectedSessionReportingTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

/// The decorator that tells the app when the Worker answers 401 to a request that carried a token.
@MainActor
struct RejectedSessionReportingTests {
    private static let token = "header.payload.signature-1234567890"

    private func request(authorization: String?, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/users/me")!)
        request.httpMethod = method
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    @Test func reportsTheTokenOf401ToARequestThatCarriedOne() async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(
            base: ScriptedHTTP(status: 401, body: #"{"error":"invalid session"}"#),
            report: { await reports.add($0) }
        )

        let response = try await client.data(request(authorization: "Bearer \(Self.token)"))

        #expect(await reports.tokens == [Self.token])
        // The client that asked still sees the 401 and decides on its own error.
        #expect(response.statusCode == 401)
        #expect(String(data: response.data, encoding: .utf8) == #"{"error":"invalid session"}"#)
    }

    @Test func reportsBeforeTheResponseIsHandedBack() async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(
            base: ScriptedHTTP(status: 401),
            report: { token in
                // A slow report still finishes first, so the session is over by the time a client throws.
                for _ in 0 ..< 5 { await Task.yield() }
                await reports.add(token)
            }
        )

        _ = try await client.data(request(authorization: "Bearer \(Self.token)"))

        #expect(await reports.tokens == [Self.token])
    }

    @Test func aGuestRequestIsNeverReported() async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(base: ScriptedHTTP(status: 401), report: { await reports.add($0) })

        let response = try await client.data(request(authorization: nil))

        #expect(response.statusCode == 401)
        #expect(await reports.tokens.isEmpty)
    }

    @Test(arguments: [200, 201, 204, 400, 403, 404, 409, 413, 422, 429, 500, 503])
    func anythingButA401IsNotReported(status: Int) async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(base: ScriptedHTTP(status: status), report: { await reports.add($0) })

        let response = try await client.data(request(authorization: "Bearer \(Self.token)"))

        #expect(response.statusCode == status)
        #expect(await reports.tokens.isEmpty)
    }

    @Test(arguments: ["Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "bearer-without-scheme", ""])
    func aHeaderThatIsNotABearerTokenIsNotReported(header: String) async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(base: ScriptedHTTP(status: 401), report: { await reports.add($0) })

        _ = try await client.data(request(authorization: header))

        #expect(await reports.tokens.isEmpty)
    }

    @Test func reportsA401ToAnUploadToo() async throws {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(base: ScriptedHTTP(status: 401), report: { await reports.add($0) })

        let response = try await client.upload(
            request(authorization: "Bearer \(Self.token)", method: "POST"),
            multipart: [.field(name: "caption", value: "hello")]
        )

        #expect(response.statusCode == 401)
        #expect(await reports.tokens == [Self.token])
    }

    @Test func aFailedRequestPassesItsErrorOnAndReportsNothing() async {
        let reports = RejectionLog()
        let client = RejectedSessionReportingHTTPClient(
            base: ScriptedHTTP(error: URLError(.notConnectedToInternet)),
            report: { await reports.add($0) }
        )

        await #expect(throws: URLError.self) {
            try await client.data(request(authorization: "Bearer \(Self.token)"))
        }
        #expect(await reports.tokens.isEmpty)
    }

    @Test func sendsTheRequestOnUnchanged() async throws {
        let base = ScriptedHTTP(status: 200)
        let client = RejectedSessionReportingHTTPClient(base: base, report: { _ in })
        let original = request(authorization: "Bearer \(Self.token)", method: "DELETE")

        _ = try await client.data(original)

        #expect(await base.requests == [original])
    }
}

// MARK: - doubles

actor RejectionLog {
    private(set) var tokens: [String] = []
    func add(_ token: String) { tokens.append(token) }
}

actor ScriptedHTTP: HTTPClient {
    private let outcome: Result<HTTPClientResponse, Error>
    private(set) var requests: [URLRequest] = []

    init(status: Int, body: String = "") {
        outcome = .success(HTTPClientResponse(data: Data(body.utf8), statusCode: status))
    }

    init(error: Error) {
        outcome = .failure(error)
    }

    func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        requests.append(request)
        return try outcome.get()
    }

    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        requests.append(request)
        return try outcome.get()
    }
}
