//
//  AccountDeletionAPIClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What the app sends to delete the signed-in account and what each answer of the Worker means for the person.
@Suite(.serialized)
@MainActor
struct AccountDeletionAPIClientTests {
    private static let authorization = DeletionTestAuthorization()

    private static func session(
        status: Int = 204,
        body: String = "",
        capture: ((URLRequest) -> Void)? = nil
    ) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    @Test func aCodeIsSentInADeleteToTheProfileURLWithTheSession() async throws {
        var captured: URLRequest?
        var capturedBody: Data?
        let session = Self.session {
            captured = $0
            capturedBody = $0.readBody()
        }
        defer { StubURLSessionFactory.reset(session) }

        try await AccountDeletionAPIClient(session: session, authorization: Self.authorization)
            .deleteAccount(authorizationCode: "code-123")

        #expect(captured?.httpMethod == "DELETE")
        #expect(captured?.url?.path().hasSuffix("/v1/users/me") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(captured?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(captured?.timeoutInterval == 60, "an Apple call, some R2 deletes and a database statement can take a while")
        let sent = try JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: String]
        #expect(sent == ["authorizationCode": "code-123"])
    }

    @Test func noCodeSendsAnEmptyObject() async throws {
        var captured: URLRequest?
        var capturedBody: Data?
        let session = Self.session {
            captured = $0
            capturedBody = $0.readBody()
        }
        defer { StubURLSessionFactory.reset(session) }

        try await AccountDeletionAPIClient(session: session, authorization: Self.authorization)
            .deleteAccount(authorizationCode: nil)

        #expect(captured?.httpMethod == "DELETE")
        #expect(String(decoding: capturedBody ?? Data(), as: UTF8.self) == "{}")
    }

    @Test(arguments: [204, 200])
    func anAnswerOfSuccessIsTheEnd(statusCode: Int) async throws {
        let session = Self.session(status: statusCode)
        defer { StubURLSessionFactory.reset(session) }

        try await AccountDeletionAPIClient(session: session, authorization: Self.authorization)
            .deleteAccount(authorizationCode: "code-123")
    }

    @Test(arguments: [
        (400, AccountDeletionError.appleNotConfirmed),
        (401, AccountDeletionError.signInRequired),
        (403, AccountDeletionError.wrongAppleAccount),
        (405, AccountDeletionError.notAvailable),
        (503, AccountDeletionError.notAvailable),
        (429, AccountDeletionError.rateLimited),
        (500, AccountDeletionError.couldNotFinish),
        (502, AccountDeletionError.couldNotFinish),
        (404, AccountDeletionError.couldNotFinish),
    ])
    func mapsStatusCodes(statusCode: Int, expected: AccountDeletionError) async {
        let session = Self.session(status: statusCode, body: #"{"error":"x"}"#)
        defer { StubURLSessionFactory.reset(session) }

        let client = AccountDeletionAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) { try await client.deleteAccount(authorizationCode: "code-123") }
    }

    @Test func tooManyClipsCarriesTheLimitTheWorkerNamed() async {
        let session = Self.session(status: 409, body: #"{"error":"x","limit":15}"#)
        defer { StubURLSessionFactory.reset(session) }

        let client = AccountDeletionAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: AccountDeletionError.tooManyClips(limit: 15)) {
            try await client.deleteAccount(authorizationCode: "code-123")
        }
    }

    /// A 409 the app cannot read says nothing it could show the person, so it is the general failure.
    @Test(arguments: ["", "not json", #"{"error":"x"}"#, #"{"limit":"15"}"#, #"{"limit":0}"#, #"{"limit":-3}"#])
    func aConflictWithoutAUsableLimitIsTheGeneralFailure(body: String) async {
        let session = Self.session(status: 409, body: body)
        defer { StubURLSessionFactory.reset(session) }

        let client = AccountDeletionAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: AccountDeletionError.couldNotFinish) {
            try await client.deleteAccount(authorizationCode: "code-123")
        }
    }

    @Test(arguments: [nil, NoSessionAuthorization() as APIAuthorization?])
    func noSessionNeverSendsARequest(authorization: APIAuthorization?) async {
        var requestCount = 0
        let session = Self.session { _ in requestCount += 1 }
        defer { StubURLSessionFactory.reset(session) }

        let client = AccountDeletionAPIClient(session: session, authorization: authorization)
        await #expect(throws: AccountDeletionError.signInRequired) {
            try await client.deleteAccount(authorizationCode: "code-123")
        }
        #expect(requestCount == 0)
    }

    /// Offline and timed out are the view model's to explain: the client lets them through as they are.
    @Test func aTransportErrorIsNotCaught() async {
        let session = StubURLSessionFactory.make { _ in throw URLError(.notConnectedToInternet) }
        defer { StubURLSessionFactory.reset(session) }

        let client = AccountDeletionAPIClient(session: session, authorization: Self.authorization)
        do {
            try await client.deleteAccount(authorizationCode: "code-123")
            Issue.record("a request that could not reach the Worker must throw")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("expected the URLError as it came, got \(error)")
        }
    }

    /// A single-use code of Apple's must not end up in a log a person may copy into a chat.
    @Test func theLogLineNamesTheRequestButNeverTheCode() async throws {
        let code = "code-\(UUID().uuidString)"
        let session = Self.session()
        defer { StubURLSessionFactory.reset(session) }

        try await AccountDeletionAPIClient(session: session, authorization: Self.authorization)
            .deleteAccount(authorizationCode: code)

        // `AppLog` writes from a task of its own, so the entry shows up a moment after the call that logged it.
        var logged = false
        for _ in 0..<300 where !logged {
            logged = AppLogStore.shared.entries.contains {
                $0.category == "api.account" && $0.message.contains("DELETE") && $0.message.contains("/v1/users/me")
            }
            if !logged { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(logged, "the request is logged")
        #expect(!AppLogStore.shared.entries.contains { $0.message.contains(code) }, "the code never reaches the log")
    }
}

private struct DeletionTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}

private struct NoSessionAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { nil }
}
