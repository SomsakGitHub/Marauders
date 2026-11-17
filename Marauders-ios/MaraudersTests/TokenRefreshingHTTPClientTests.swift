//
//  TokenRefreshingHTTPClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

/// The decorator that heals a 401: a request that carried a token and was rejected is sent once more with a new one,
/// and a caller never sees the 401 of a session that is still alive.
@MainActor
struct TokenRefreshingHTTPClientTests {
    private func request(token: String? = "old", method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/clips?limit=20")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" { request.httpBody = Data(#"{"caption":"hello"}"#.utf8) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// What the decorator throws for a request that met a 401 and an unavailable refresh, or nil when it answered.
    private func thrownError(
        whenRefreshIs outcome: TokenRefreshOutcome
    ) async -> (error: (any Error)?, transportRequests: Int) {
        let transport = RecordingTransport([.success(reply(401))])
        let client = TokenRefreshingHTTPClient(base: transport, refresher: ScriptedRefresher(outcome))
        do {
            _ = try await client.data(request())
            return (nil, transport.requests.count)
        } catch {
            return (error, transport.requests.count)
        }
    }

    // MARK: - what is left alone

    @Test(arguments: [200, 404, 500])
    func aResponseThatIsNot401GoesBackUntouched(status: Int) async throws {
        let transport = RecordingTransport([.success(reply(status, body: "answer"))])
        let refresher = ScriptedRefresher()
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)

        let response = try await client.data(request())

        #expect(response.statusCode == status)
        #expect(String(decoding: response.data, as: UTF8.self) == "answer")
        #expect(transport.requests.count == 1)
        #expect(refresher.asked.isEmpty)
    }

    @Test(arguments: [false, true])
    func a401ToAGuestGoesBackUntouched(isUpload: Bool) async throws {
        let transport = RecordingTransport([.success(reply(401, body: "who are you"))])
        let refresher = ScriptedRefresher()
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)
        let guest = request(token: nil, method: isUpload ? "POST" : "GET")

        let response: HTTPClientResponse
        if isUpload {
            response = try await client.upload(guest, multipart: [.field(name: "caption", value: "hello")])
        } else {
            response = try await client.data(guest)
        }

        #expect(response.statusCode == 401)
        #expect(String(decoding: response.data, as: UTF8.self) == "who are you")
        #expect(transport.requests == [guest])
        #expect(refresher.asked.isEmpty)
    }

    @Test(arguments: ["Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "bearer-without-scheme", ""])
    func a401ToAnAuthorizationThatIsNotABearerTokenGoesBackUntouched(header: String) async throws {
        let transport = RecordingTransport([.success(reply(401))])
        let refresher = ScriptedRefresher()
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)
        var odd = request(token: nil)
        odd.setValue(header, forHTTPHeaderField: "Authorization")

        let response = try await client.data(odd)

        #expect(response.statusCode == 401)
        #expect(transport.requests.count == 1)
        #expect(refresher.asked.isEmpty)
    }

    @Test func aRequestThatFailsInTransportThrowsThatErrorAndAsksNoOne() async {
        let transport = RecordingTransport([.failure(URLError(.timedOut))])
        let refresher = ScriptedRefresher()
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)

        await #expect(throws: URLError.self) { try await client.data(request()) }

        #expect(transport.requests.count == 1)
        #expect(refresher.asked.isEmpty)
    }

    // MARK: - a 401 to a request that carried a token

    @Test func a401WithABearerIsReplayedOnceWithTheNewToken() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200, body: "fresh"))])
        let refresher = ScriptedRefresher(.refreshed("new"))
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)
        // A POST with a body, to show the replay is the same request in everything but the token.
        let original = request(method: "POST")

        let response = try await client.data(original)

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.data, as: UTF8.self) == "fresh")
        #expect(refresher.asked == ["old"])
        #expect(transport.requests.count == 2)
        #expect(transport.requests.first == original)
        var expected = original
        expected.setValue("Bearer new", forHTTPHeaderField: "Authorization")
        #expect(transport.requests.last == expected)
    }

    @Test(arguments: [403, 404, 429, 500, 503])
    func aReplayThatAnswersAnythingIsReturnedAsIs(status: Int) async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(status, body: "replayed"))])
        let refresher = ScriptedRefresher(.refreshed("new"))
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)

        let response = try await client.data(request())

        #expect(response.statusCode == status)
        #expect(String(decoding: response.data, as: UTF8.self) == "replayed")
        #expect(transport.requests.count == 2)
        #expect(refresher.asked == ["old"], "no second refresh")
    }

    @Test func aReplayRejectedAgainReportsTheNewTokenAndReturnsThe401() async throws {
        let reports = RejectionLog()
        let transport = RecordingTransport([.success(reply(401)), .success(reply(401, body: "again"))])
        let refresher = ScriptedRefresher(.refreshed("new"))
        let client = TokenRefreshingHTTPClient(
            base: transport, refresher: refresher, reportRejectedReplay: { await reports.add($0) })

        let response = try await client.data(request())

        #expect(response.statusCode == 401)
        #expect(String(decoding: response.data, as: UTF8.self) == "again")
        #expect(await reports.tokens == ["new"])
        #expect(transport.requests.count == 2, "no third request")
        #expect(refresher.asked == ["old"])
    }

    @Test func aReplayThatIsNotRejectedReportsNothing() async throws {
        let reports = RejectionLog()
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200))])
        let client = TokenRefreshingHTTPClient(
            base: transport, refresher: ScriptedRefresher(.refreshed("new")),
            reportRejectedReplay: { await reports.add($0) })

        _ = try await client.data(request())

        #expect(await reports.tokens.isEmpty)
    }

    @Test func aReplayThatFailsInTransportThrowsThatError() async {
        let transport = RecordingTransport([.success(reply(401)), .failure(URLError(.networkConnectionLost))])
        let reports = RejectionLog()
        let client = TokenRefreshingHTTPClient(
            base: transport, refresher: ScriptedRefresher(.refreshed("new")),
            reportRejectedReplay: { await reports.add($0) })

        await #expect(throws: URLError.self) { try await client.data(request()) }

        #expect(transport.requests.count == 2)
        #expect(await reports.tokens.isEmpty)
    }

    @Test func aRejectedRefreshReturnsTheOriginal401WithoutReplaying() async throws {
        let reports = RejectionLog()
        let transport = RecordingTransport([.success(reply(401, body: "original"))])
        let refresher = ScriptedRefresher(.rejected)
        let client = TokenRefreshingHTTPClient(
            base: transport, refresher: refresher, reportRejectedReplay: { await reports.add($0) })

        let response = try await client.data(request())

        #expect(response.statusCode == 401)
        #expect(String(decoding: response.data, as: UTF8.self) == "original")
        #expect(transport.requests.count == 1)
        #expect(refresher.asked == ["old"])
        #expect(await reports.tokens.isEmpty, "the caller's own rejection report ends the session, not this one")
    }

    @Test func anUnavailableRefreshThrowsAndNeverShowsA401() async {
        // Anything that is not a transport error of the refresh call itself is one typed error.
        let failures: [any Error] = [
            AuthAPIError.serverError(503),
            AuthAPIError.serverError(429),
            AuthAPIError.serverError(404),
            AuthAPIError.invalidResponse,
            HTTPClientError.transport("offline"),
            ScriptedRefresher.NothingScripted(),
        ]
        for failure in failures {
            let result = await thrownError(whenRefreshIs: .unavailable(failure))

            #expect(result.error as? SessionRefreshUnavailableError == SessionRefreshUnavailableError(), "\(failure)")
            #expect(result.transportRequests == 1, "\(failure)")
        }

        // A transport error comes through as it is, so a caller's own retry of transient failures still applies.
        let offline = URLError(.notConnectedToInternet)
        let result = await thrownError(whenRefreshIs: .unavailable(offline))

        #expect(result.error as? URLError == offline)
        #expect(result.transportRequests == 1)
    }

    @Test func theTypedErrorReadsAsAServiceError() {
        let message = SessionRefreshUnavailableError().errorDescription

        #expect(message == "The service is temporarily unavailable. Please try again.")
    }

    // MARK: - uploads

    @Test func anUploadIsReplayedWithTheSamePartsAndTheNewToken() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(201))])
        let refresher = ScriptedRefresher(.refreshed("new"))
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)
        let parts: [HTTPMultipartPart] = [
            .field(name: "caption", value: "hello"),
            .file(name: "video", filename: "clip.mp4", mimeType: "video/mp4", data: Data([1, 2, 3, 4])),
        ]
        let original = request(method: "POST")

        let response = try await client.upload(original, multipart: parts)

        #expect(response.statusCode == 201)
        #expect(refresher.asked == ["old"])
        #expect(transport.requests.count == 2)
        #expect(
            transport.uploadedParts == [
                [
                    .field(name: "caption", value: "hello"),
                    .file(name: "video", filename: "clip.mp4", mimeType: "video/mp4", data: Data([1, 2, 3, 4])),
                ],
                [
                    .field(name: "caption", value: "hello"),
                    .file(name: "video", filename: "clip.mp4", mimeType: "video/mp4", data: Data([1, 2, 3, 4])),
                ],
            ], "the same parts go out twice")
        var expected = original
        expected.setValue("Bearer new", forHTTPHeaderField: "Authorization")
        #expect(transport.requests.last == expected)
    }

    @Test func anUploadReportsProgressForTheFirstTryAndTheReplay() async throws {
        let transport = RecordingTransport(
            [.success(reply(401)), .success(reply(201))], reportingProgress: [0.5, 1.0])
        let client = TokenRefreshingHTTPClient(base: transport, refresher: ScriptedRefresher(.refreshed("new")))
        let log = UploadProgressLog()

        let response = try await client.upload(
            request(method: "POST"), multipart: [.field(name: "caption", value: "hello")], progress: log.handler)

        #expect(response.statusCode == 201)
        #expect(transport.requests.count == 2)
        #expect(
            log.values == [0.5, 1.0, 0.5, 1.0], "the replay sends the body again, from 0, through the same handler")
    }

    @Test func anUploadWhoseRefreshIsRejectedOrUnavailableIsNotReplayed() async throws {
        let parts: [HTTPMultipartPart] = [.field(name: "caption", value: "hello")]

        let rejectedTransport = RecordingTransport([.success(reply(401))])
        let rejected = TokenRefreshingHTTPClient(base: rejectedTransport, refresher: ScriptedRefresher(.rejected))
        let response = try await rejected.upload(request(method: "POST"), multipart: parts)
        #expect(response.statusCode == 401)
        #expect(rejectedTransport.uploadedParts.count == 1)

        let unavailableTransport = RecordingTransport([.success(reply(401))])
        let unavailable = TokenRefreshingHTTPClient(
            base: unavailableTransport, refresher: ScriptedRefresher(.unavailable(AuthAPIError.serverError(500))))
        await #expect(throws: SessionRefreshUnavailableError.self) {
            try await unavailable.upload(request(method: "POST"), multipart: parts)
        }
        #expect(unavailableTransport.uploadedParts.count == 1)
    }

    // MARK: - with the real refresher

    @Test(.timeLimit(.minutes(1)))
    func fiveRejectedRequestsMakeOneRefreshAndFiveReplays() async throws {
        let oldToken = TestAccessToken.make(subject: "user-1", expiresIn: 60)
        let newToken = TestAccessToken.make(subject: "user-1", expiresIn: 86_400)
        let gate = SignOutGate()
        let api = ScriptedAuthAPI(gate: gate)
        api.enqueue(.success(AuthTokens(accessToken: newToken, refreshToken: newRefreshToken())))
        let refresher = TokenRefresher(
            accessTokenStore: SignOutSessionStorage(accessToken: oldToken),
            refreshTokenStore: MemoryRefreshTokenStore(token: newRefreshToken()),
            authAPI: api, retryDelay: .zero)
        // The Worker accepts the new token and rejects every other.
        let transport = RecordingTransport(responder: { request in
            request.bearerToken == newToken ? reply(200) : reply(401)
        })
        let client = TokenRefreshingHTTPClient(base: transport, refresher: refresher)
        let original = request(token: oldToken)

        let callers = (0..<5).map { _ in Task { try await client.data(original) } }
        await api.waitForCalls(1)
        // Time for the other four to meet their 401 and reach the refresher while the call is in flight.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()

        for caller in callers {
            #expect(try await caller.value.statusCode == 200)
        }
        #expect(api.refreshCalls == 1)
        #expect(transport.requests.count == 10, "five that were rejected and five replays")
        #expect(transport.requests.filter { $0.bearerToken == newToken }.count == 5)
        #expect(transport.requests.filter { $0.bearerToken == oldToken }.count == 5)
    }
}

// MARK: - the bearer token of a request

struct URLRequestBearerTokenTests {
    private func request(authorization: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/users/me")!)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    @Test(arguments: [
        ("Bearer abc.def.ghi", "abc.def.ghi"),
        ("Bearer   abc.def.ghi  ", "abc.def.ghi"),
        ("Bearer header.payload.signature-1234567890", "header.payload.signature-1234567890"),
    ])
    func readsTheTokenOfABearerHeader(header: String, token: String) {
        #expect(request(authorization: header).bearerToken == token)
    }

    @Test(arguments: ["Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "Bearer    ", "bearer abc", "Token abc", ""])
    func aHeaderThatIsNotABearerTokenHasNone(header: String) {
        #expect(request(authorization: header).bearerToken == nil)
    }

    @Test func aRequestWithoutAnAuthorizationHeaderHasNoBearerToken() {
        #expect(request(authorization: nil).bearerToken == nil)
    }
}

// MARK: - helpers

private func newRefreshToken() -> String {
    // 32 hex characters and 11 more make 43 base64url characters, the shape the Worker issues.
    UUID().uuidString.replacingOccurrences(of: "-", with: "") + "-_abcdefghi"
}

private nonisolated func reply(_ status: Int, body: String = "") -> HTTPClientResponse {
    HTTPClientResponse(data: Data(body.utf8), statusCode: status)
}
