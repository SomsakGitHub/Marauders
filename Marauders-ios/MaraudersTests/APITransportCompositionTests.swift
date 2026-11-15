//
//  APITransportCompositionTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders

/// The transports that tell the session its token was rejected.
nonisolated enum ReportingStack: Sendable, CustomTestStringConvertible {
    case api
    case feed

    var testDescription: String {
        switch self {
        case .api: "api"
        case .feed: "feed"
        }
    }
}

/// How the app's transports are layered. Each test sends a request through a stack over a scripted base transport and a
/// scripted refresher, so what it checks is the order of the layers, what each one reports and what reaches the caller,
/// not the layers themselves.
@MainActor
struct APITransportCompositionTests {
    private static let userID = "001234.abcdef.5678"
    /// The shape of a real refresh token: 43 base64url characters.
    private static let firstRefreshToken = String(repeating: "Ab-_0", count: 8) + "xyz"
    private static let secondRefreshToken = String(repeating: "Zy_-9", count: 8) + "abc"

    private func request(token: String?, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/users/me")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func stack(
        _ kind: ReportingStack, base: any HTTPClient, refresher: any TokenRefreshing,
        report: @escaping @Sendable (String) async -> Void
    ) -> any HTTPClient {
        switch kind {
        case .api: APITransportComposition.api(base: base, refresher: refresher, reportRejected: report)
        case .feed: APITransportComposition.feed(base: base, refresher: refresher, reportRejected: report)
        }
    }

    // MARK: - the api stack: reporter ← refresh ← retry ← base

    @Test func theApiStackRetriesAReplay() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(503)), .success(reply(200))])
        let log = RejectionLog()
        let client = APITransportComposition.api(
            base: transport, refresher: ScriptedRefresher(.refreshed("new")), reportRejected: { await log.add($0) })

        let response = try await client.data(request(token: "old"))

        #expect(response.statusCode == 200)
        // The retry sits under the refresh: the 503 of the replay is tried again with the new token, not the old.
        #expect(transport.requests.map(\.bearerToken) == ["old", "new", "new"])
        #expect(await log.tokens.isEmpty)
    }

    // MARK: - the stacks that report: api and feed

    @Test(arguments: [ReportingStack.api, ReportingStack.feed])
    func aFreshSessionIsNeverReported(kind: ReportingStack) async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200))])
        let log = RejectionLog()
        let client = stack(kind, base: transport, refresher: ScriptedRefresher(.refreshed("new"))) {
            await log.add($0)
        }

        let response = try await client.data(request(token: "old"))

        #expect(response.statusCode == 200)
        #expect(transport.requests.map(\.bearerToken) == ["old", "new"])
        #expect(await log.tokens.isEmpty, "a 401 that the refresh healed is not the end of the session")
    }

    @Test(arguments: [ReportingStack.api, ReportingStack.feed])
    func aRejectedRefreshReportsTheOldToken(kind: ReportingStack) async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200))])
        let log = RejectionLog()
        let client = stack(kind, base: transport, refresher: ScriptedRefresher(.rejected)) { await log.add($0) }

        let response = try await client.data(request(token: "old"))

        #expect(response.statusCode == 401)
        #expect(transport.requests.count == 1, "nothing is replayed after a refusal")
        #expect(await log.tokens == ["old"])
    }

    @Test(arguments: [ReportingStack.api, ReportingStack.feed])
    func aReplayRejectedAgainReportsTheNewTokenThenTheOld(kind: ReportingStack) async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(401))])
        let log = RejectionLog()
        let client = stack(kind, base: transport, refresher: ScriptedRefresher(.refreshed("new"))) {
            await log.add($0)
        }

        let response = try await client.data(request(token: "old"))

        #expect(response.statusCode == 401)
        // The session has moved on to the new token, so that is the report that counts; the old one is ignored by it.
        #expect(await log.tokens == ["new", "old"])
    }

    @Test func aReplayRejectedAgainEndsTheSessionWithTheNewToken() async throws {
        let oldToken = TestAccessToken.make(subject: "user-1", expiresIn: 3_600)
        let newToken = TestAccessToken.make(subject: "user-1", expiresIn: 86_400)
        let session = SignOutSessionStorage(userID: Self.userID, accessToken: oldToken)
        let refreshStore = MemoryRefreshTokenStore(token: Self.firstRefreshToken)
        let api = ScriptedAuthAPI()
        api.enqueue(.success(AuthTokens(accessToken: newToken, refreshToken: Self.secondRefreshToken)))
        let viewModel = AuthViewModel(
            sessionStore: session, tokenStore: session, refreshTokenStore: refreshStore, authAPI: api,
            credentialState: { _ in .authorized })
        await viewModel.restoreSession()
        try #require(viewModel.isSignedIn)
        let refresher = TokenRefresher(
            accessTokenStore: session, refreshTokenStore: refreshStore, authAPI: api, retryDelay: .zero)
        // The Worker rejects the old token, and the new one as well.
        let transport = RecordingTransport([.success(reply(401)), .success(reply(401))])
        let client = APITransportComposition.api(
            base: transport, refresher: refresher, reportRejected: { await viewModel.handleRejectedAccessToken($0) })

        let response = try await client.data(request(token: oldToken))

        #expect(response.statusCode == 401)
        #expect(api.refreshTokensGiven == [Self.firstRefreshToken])
        #expect(transport.requests.map(\.bearerToken) == [oldToken, newToken])
        #expect(!viewModel.isSignedIn)
        #expect(session.userID == nil)
        #expect(session.accessToken == nil)
        #expect(refreshStore.token == nil)
    }

    @Test func aRejectedUITestSessionStillEndsOnThe401() async throws {
        // The three in-memory stores of the rejected-session UI tests, holding a token that `restoreSession` accepts
        // outside a UI test. They have no refresh token, so there is nothing to spend and the 401 ends the session.
        let session = UITestRejectedSession()
        let token = TestAccessToken.make(expiresIn: 3_600)
        try session.saveAccessToken(token)
        let api = ScriptedAuthAPI()
        let viewModel = AuthViewModel(
            sessionStore: session, tokenStore: session, refreshTokenStore: session, authAPI: api,
            credentialState: { _ in .authorized })
        await viewModel.restoreSession()
        try #require(viewModel.isSignedIn)
        let refresher = TokenRefresher(
            accessTokenStore: session, refreshTokenStore: session, authAPI: api, retryDelay: .zero)
        let client = APITransportComposition.api(
            base: UITestRejectingHTTPClient(), refresher: refresher,
            reportRejected: { await viewModel.handleRejectedAccessToken($0) })

        let response = try await client.data(request(token: token))

        #expect(response.statusCode == 401)
        #expect(api.refreshCalls == 0, "no refresh token, so the Worker is not asked")
        #expect(!viewModel.isSignedIn)
        #expect(session.loadUserID() == nil)
        #expect(session.loadAccessToken() == nil)
    }

    // MARK: - the feed stack: reporter ← refresh ← base

    @Test func theFeedStackHasNoRetryLayer() async throws {
        let log = RejectionLog()

        // The feed repeats its own reads, so a transient failure goes back to it at once, before and after a refresh.
        let rejectedThenDown = RecordingTransport([.success(reply(401)), .success(reply(503)), .success(reply(200))])
        let afterRefresh = APITransportComposition.feed(
            base: rejectedThenDown, refresher: ScriptedRefresher(.refreshed("new")),
            reportRejected: { await log.add($0) })
        #expect(try await afterRefresh.data(request(token: "old")).statusCode == 503)
        #expect(rejectedThenDown.requests.count == 2, "one send and one replay, no retry of the 503")

        let down = RecordingTransport([.success(reply(503)), .success(reply(200))])
        let plain = APITransportComposition.feed(
            base: down, refresher: ScriptedRefresher(), reportRejected: { await log.add($0) })
        #expect(try await plain.data(request(token: "old")).statusCode == 503)
        #expect(down.requests.count == 1, "a 503 on the first send is not tried again either")

        #expect(await log.tokens.isEmpty)
    }

    // MARK: - the quiet stack: refresh ← base

    @Test func theQuietStackRefreshesAndReplays() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200))])
        let client = APITransportComposition.quiet(base: transport, refresher: ScriptedRefresher(.refreshed("new")))

        // A background location report whose 1-day token has run out.
        let response = try await client.data(request(token: "old", method: "POST"))

        #expect(response.statusCode == 200)
        #expect(transport.requests.map(\.bearerToken) == ["old", "new"])
    }

    @Test func theQuietStackStopsAt401() async throws {
        // A refusal gives the 401 back, and so does a replay that is rejected again. What a caller does with it
        // (`BackgroundLocationMonitor` stops sharing) is its own business: there is no reporter to end the session.
        let refused = RecordingTransport([.success(reply(401))])
        let afterRefusal = APITransportComposition.quiet(base: refused, refresher: ScriptedRefresher(.rejected))
        #expect(try await afterRefusal.data(request(token: "old")).statusCode == 401)
        #expect(refused.requests.count == 1)

        let rejectedTwice = RecordingTransport([.success(reply(401)), .success(reply(401))])
        let afterReplay = APITransportComposition.quiet(
            base: rejectedTwice, refresher: ScriptedRefresher(.refreshed("new")))
        #expect(try await afterReplay.data(request(token: "old")).statusCode == 401)
        #expect(rejectedTwice.requests.map(\.bearerToken) == ["old", "new"])
    }

    @Test func theQuietStackHasNoRetryLayer() async throws {
        let transport = RecordingTransport([.success(reply(503)), .success(reply(200))])
        let client = APITransportComposition.quiet(base: transport, refresher: ScriptedRefresher())

        #expect(try await client.data(request(token: "old")).statusCode == 503)
        #expect(transport.requests.count == 1)
    }
}

private nonisolated func reply(_ status: Int, body: String = "") -> HTTPClientResponse {
    HTTPClientResponse(data: Data(body.utf8), statusCode: status)
}
