//
//  AuthAPIClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct AuthAPIClientTests {
    private static let identityToken = String(repeating: "i", count: 32)
    private static let accessToken = String(repeating: "a", count: 40)
    private static let nextAccessToken = String(repeating: "n", count: 40)
    /// The shape of a real refresh token: 43 base64url characters.
    private static let refreshToken = String(repeating: "Ab-_0", count: 8) + "xyz"
    private static let nextRefreshToken = String(repeating: "Zy_-9", count: 8) + "abc"

    private static func pair(_ access: String, _ refresh: String) -> String {
        #"{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}"#
    }

    /// A session that answers every request with `status` and `body`, and hands the request it got to `capture`.
    private static func session(status: Int = 200, body: String, capture: ((URLRequest) -> Void)? = nil) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    private static func sentBody(_ request: URLRequest?) -> String {
        String(decoding: request?.readBody() ?? Data(), as: UTF8.self)
    }

    // MARK: sign-in

    @Test func signInSendsTheOptInFlagAndReadsThePair() async throws {
        var captured: URLRequest?
        let session = Self.session(body: Self.pair(Self.accessToken, Self.refreshToken)) { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let tokens = try await AuthAPIClient(session: session)
            .exchangeAppleIdentityToken(Self.identityToken, countryCode: "th")

        #expect(captured?.httpMethod == "POST")
        #expect(captured?.url?.path().hasSuffix("/v1/auth/apple") == true)
        let sent = try JSONSerialization.jsonObject(with: try #require(captured?.readBody())) as? [String: Any]
        #expect(sent?["identityToken"] as? String == Self.identityToken)
        #expect(sent?["country"] as? String == "TH")
        #expect(Self.sentBody(captured).contains(#""supportsRefreshTokens":true"#), "a JSON boolean, not 1 or a string")
        #expect(tokens == AuthTokens(accessToken: Self.accessToken, refreshToken: Self.refreshToken))
    }

    @Test func anAnswerWithoutARefreshTokenGivesNil() async throws {
        let session = Self.session(body: #"{"accessToken":"\#(Self.accessToken)"}"#)
        defer { StubURLSessionFactory.reset(session) }

        let tokens = try await AuthAPIClient(session: session)
            .exchangeAppleIdentityToken(Self.identityToken, countryCode: "TH")

        #expect(tokens == AuthTokens(accessToken: Self.accessToken, refreshToken: nil))
    }

    @Test func aRefreshTokenOfTheWrongShapeInASignInAnswerIsInvalid() async {
        for refreshToken in ["", "short", Self.refreshToken + "=", Self.refreshToken + " "] {
            let session = Self.session(body: Self.pair(Self.accessToken, refreshToken))
            defer { StubURLSessionFactory.reset(session) }

            await #expect(throws: AuthAPIError.invalidResponse, "\(refreshToken.debugDescription)") {
                try await AuthAPIClient(session: session)
                    .exchangeAppleIdentityToken(Self.identityToken, countryCode: "TH")
            }
        }
    }

    @Test func signInAnswering401IsAnInvalidIdentityToken() async {
        let session = Self.session(status: 401, body: #"{"error":"invalid identity token"}"#)
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: AuthAPIError.invalidIdentityToken) {
            try await AuthAPIClient(session: session).exchangeAppleIdentityToken(Self.identityToken, countryCode: "TH")
        }
    }

    @Test func signInAnswering503IsAServerErrorWithTheStatus() async {
        let session = Self.session(status: 503, body: "")
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: AuthAPIError.serverError(503)) {
            try await AuthAPIClient(session: session).exchangeAppleIdentityToken(Self.identityToken, countryCode: "TH")
        }
    }

    // MARK: refresh

    @Test func refreshPostsTheTokenWithoutAnAuthorizationHeader() async throws {
        var captured: URLRequest?
        let session = Self.session(body: Self.pair(Self.nextAccessToken, Self.nextRefreshToken)) { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let tokens = try await AuthAPIClient(session: session).refreshTokens(using: Self.refreshToken)

        #expect(captured?.httpMethod == "POST")
        #expect(captured?.url?.path().hasSuffix("/v1/auth/refresh") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(captured?.timeoutInterval == 30)
        #expect(Self.sentBody(captured) == #"{"refreshToken":"\#(Self.refreshToken)"}"#)
        #expect(tokens == AuthTokens(accessToken: Self.nextAccessToken, refreshToken: Self.nextRefreshToken))
    }

    @Test(arguments: [400, 401])
    func refreshAnswering400Or401IsRefreshRejected(status: Int) async {
        let session = Self.session(status: status, body: #"{"error":"invalid refresh token"}"#)
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: AuthAPIError.refreshRejected) {
            try await AuthAPIClient(session: session).refreshTokens(using: Self.refreshToken)
        }
    }

    @Test(arguments: [429, 500, 502, 503, 404, 405])
    func refreshAnswering429500502503404405IsServerErrorWithTheStatus(status: Int) async {
        let session = Self.session(status: status, body: "")
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: AuthAPIError.serverError(status)) {
            try await AuthAPIClient(session: session).refreshTokens(using: Self.refreshToken)
        }
    }

    @Test func aRefreshAnswerWithoutAValidPairIsInvalid() async {
        let bodies = [
            #"{"accessToken":"\#(Self.accessToken)"}"#,
            #"{"accessToken":"\#(Self.accessToken)","refreshToken":null}"#,
            Self.pair(Self.accessToken, ""),
            Self.pair(Self.accessToken, "short"),
            Self.pair(Self.accessToken, Self.refreshToken + "+"),
            Self.pair("short", Self.refreshToken),
        ]
        for body in bodies {
            let session = Self.session(body: body)
            defer { StubURLSessionFactory.reset(session) }

            await #expect(throws: AuthAPIError.invalidResponse, "\(body)") {
                try await AuthAPIClient(session: session).refreshTokens(using: Self.refreshToken)
            }
        }
    }

    @Test func aRefreshAnswerThatIsNotTheExpectedJSONIsInvalid() async {
        for body in ["", "not json", "{}", "[]", #"{"accessToken":5,"refreshToken":5}"#] {
            let session = Self.session(body: body)
            defer { StubURLSessionFactory.reset(session) }

            await #expect(throws: AuthAPIError.invalidResponse, "\(body.debugDescription)") {
                try await AuthAPIClient(session: session).refreshTokens(using: Self.refreshToken)
            }
        }
    }

    @Test func aRejectedRefreshReadsAsAnEndedSession() {
        #expect(AuthAPIError.refreshRejected.errorDescription == "Your session has ended. Please sign in again.")
        #expect(AuthAPIError.refreshRejected.httpStatusCode == nil)
    }

    // MARK: revoke

    @Test(arguments: [200, 204])
    func revokePostsToThatRouteAndAcceptsAny2xx(status: Int) async throws {
        var captured: URLRequest?
        let session = Self.session(status: status, body: "") { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        try await AuthAPIClient(session: session).revokeRefreshToken(Self.refreshToken)

        #expect(captured?.httpMethod == "POST")
        #expect(captured?.url?.path().hasSuffix("/v1/auth/signout") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(captured?.timeoutInterval == 10)
        #expect(Self.sentBody(captured) == #"{"refreshToken":"\#(Self.refreshToken)"}"#)
    }

    @Test(arguments: [500, 400, 429])
    func aRevokeTheWorkerDoesNotAcceptIsAServerErrorWithTheStatus(status: Int) async {
        let session = Self.session(status: status, body: "")
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: AuthAPIError.serverError(status)) {
            try await AuthAPIClient(session: session).revokeRefreshToken(Self.refreshToken)
        }
    }

    // MARK: dev sign-in

    #if DEBUG
        @Test func theDevClientSendsTheFlagToo() async throws {
            var captured: URLRequest?
            let session = Self.session(body: Self.pair(Self.accessToken, Self.refreshToken)) { captured = $0 }
            defer { StubURLSessionFactory.reset(session) }

            let tokens = try await DevAuthAPIClient(client: URLSessionHTTPClient(session: session))
                .tokens(secret: "shared-secret", label: "alice", countryCode: "nl")

            #expect(captured?.url?.path().hasSuffix("/v1/auth/dev") == true)
            let sent = try JSONSerialization.jsonObject(with: try #require(captured?.readBody())) as? [String: Any]
            #expect(sent?["secret"] as? String == "shared-secret")
            #expect(sent?["label"] as? String == "alice")
            #expect(sent?["country"] as? String == "NL")
            #expect(Self.sentBody(captured).contains(#""supportsRefreshTokens":true"#), "a JSON boolean")
            #expect(tokens == AuthTokens(accessToken: Self.accessToken, refreshToken: Self.refreshToken))
        }
    #endif
}
