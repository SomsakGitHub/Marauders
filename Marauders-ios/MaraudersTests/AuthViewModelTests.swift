//
//  AuthViewModelTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders

@MainActor
struct AuthViewModelTests {
    /// The shape of a real refresh token: 43 base64url characters.
    private static let refreshToken = String(repeating: "Ab-_0", count: 8) + "xyz"
    private static let userID = "001234.abcdef.5678"

    @Test func completeSignInPersistsUserAndAccessToken() async {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: StubAuthAPIClient()
        )

        await viewModel.completeSignIn(userID: "001234.abcdef.5678", identityToken: String(repeating: "a", count: 32))

        #expect(viewModel.isSignedIn)
        #expect(store.savedUserID == "001234.abcdef.5678")
        #expect(tokenStore.savedToken == StubAuthAPIClient.stubToken)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func completeSignInKeepsTheRefreshTokenTheWorkerGave() async {
        let refresh = MemoryRefreshTokenStore(token: String(repeating: "s", count: 43))
        let viewModel = AuthViewModel(
            sessionStore: InMemoryAuthSessionStore(),
            tokenStore: InMemoryAPIAccessTokenStore(),
            refreshTokenStore: refresh,
            authAPI: StubAuthAPIClient(refreshToken: Self.refreshToken)
        )

        await viewModel.completeSignIn(userID: Self.userID, identityToken: String(repeating: "a", count: 32))

        #expect(viewModel.isSignedIn)
        #expect(refresh.token == Self.refreshToken, "the new pair replaces what an earlier session left")
    }

    @Test func completeSignInRejectsEmptyUserID() async {
        let store = InMemoryAuthSessionStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: InMemoryAPIAccessTokenStore(),
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: StubAuthAPIClient()
        )

        await viewModel.completeSignIn(userID: "   ", identityToken: String(repeating: "a", count: 32))

        #expect(!viewModel.isSignedIn)
        #expect(viewModel.errorMessage == "Invalid account")
    }

    @Test func completeSignInShowsFriendlyMessageForServerError() async {
        let viewModel = AuthViewModel(
            sessionStore: InMemoryAuthSessionStore(),
            tokenStore: InMemoryAPIAccessTokenStore(),
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: FailingAuthAPIClient(error: AuthAPIError.serverError(503))
        )

        await viewModel.completeSignIn(userID: "user-1", identityToken: String(repeating: "a", count: 32))

        #expect(!viewModel.isSignedIn)
        #expect(viewModel.errorMessage == "The service is temporarily unavailable. Please try again.")
        #expect(viewModel.errorMessage?.contains("503") == false)
    }

    @Test func completeSignInShowsFriendlyMessageForClientError() async {
        let viewModel = AuthViewModel(
            sessionStore: InMemoryAuthSessionStore(),
            tokenStore: InMemoryAPIAccessTokenStore(),
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: FailingAuthAPIClient(error: AuthAPIError.serverError(400))
        )

        await viewModel.completeSignIn(userID: "user-1", identityToken: String(repeating: "a", count: 32))

        #expect(viewModel.errorMessage == "Sign in failed. Please try again.")
    }

    @Test func serverErrorExposesStatusCodeForLogging() {
        #expect(AuthAPIError.serverError(503).httpStatusCode == 503)
        #expect(AuthAPIError.invalidIdentityToken.httpStatusCode == nil)
        #expect(AuthAPIError.invalidResponse.httpStatusCode == nil)
    }

    @Test func completeSignInForwardsSelectedCountry() async {
        let client = RecordingAuthAPIClient()
        let viewModel = AuthViewModel(
            sessionStore: InMemoryAuthSessionStore(),
            tokenStore: InMemoryAPIAccessTokenStore(),
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: client
        )
        viewModel.selectedCountryCode = "JP"

        await viewModel.completeSignIn(
            userID: "user-1",
            identityToken: String(repeating: "a", count: 32)
        )

        #expect(client.receivedCountryCode == "JP")
        #expect(viewModel.isSignedIn)
    }

    @Test func signOutClearsSessionAndToken() async {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: StubAuthAPIClient()
        )
        await viewModel.completeSignIn(userID: "user-1", identityToken: String(repeating: "b", count: 32))

        await viewModel.signOut()

        #expect(!viewModel.isSignedIn)
        #expect(store.savedUserID == nil)
        #expect(tokenStore.savedToken == nil)
    }

    @Test func signingOutClearsBothTokens() async throws {
        let tokenStore = InMemoryAPIAccessTokenStore()
        let refresh = MemoryRefreshTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: InMemoryAuthSessionStore(),
            tokenStore: tokenStore,
            refreshTokenStore: refresh,
            authAPI: StubAuthAPIClient(refreshToken: Self.refreshToken)
        )
        await viewModel.completeSignIn(userID: "user-1", identityToken: String(repeating: "b", count: 32))
        try #require(refresh.token == Self.refreshToken)
        try #require(tokenStore.savedToken != nil)

        await viewModel.signOut()

        #expect(tokenStore.savedToken == nil)
        #expect(refresh.token == nil)
    }

    @Test func aRejectedTokenClearsTheRefreshTokenToo() {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let refresh = MemoryRefreshTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            refreshTokenStore: refresh,
            authAPI: StubAuthAPIClient()
        )
        let token = TestAccessToken.make(expiresIn: 3_600)
        store.savedUserID = Self.userID
        tokenStore.savedToken = token
        refresh.token = Self.refreshToken

        viewModel.handleRejectedAccessToken(token)

        #expect(store.savedUserID == nil)
        #expect(tokenStore.savedToken == nil)
        #expect(refresh.token == nil)
    }

    @Test func restoringWithAnUnreadableUserIDClearsTheRefreshToken() async {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let refresh = MemoryRefreshTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            refreshTokenStore: refresh,
            authAPI: StubAuthAPIClient()
        )
        store.savedUserID = "   "
        tokenStore.savedToken = TestAccessToken.make(expiresIn: 3_600)
        refresh.token = Self.refreshToken

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(store.savedUserID == nil)
        #expect(tokenStore.savedToken == nil)
        #expect(refresh.token == nil)
    }
}

private struct StubAuthAPIClient: AuthAPIClientProtocol {
    static let stubToken = String(repeating: "x", count: 40)

    /// What the Worker hands out with the access token, when it hands one out.
    var refreshToken: String?

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        AuthTokens(accessToken: Self.stubToken, refreshToken: refreshToken)
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

private struct FailingAuthAPIClient: AuthAPIClientProtocol {
    let error: AuthAPIError

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        throw error
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

private final class RecordingAuthAPIClient: AuthAPIClientProtocol, @unchecked Sendable {
    private(set) var receivedCountryCode: String?

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        receivedCountryCode = countryCode
        return AuthTokens(accessToken: String(repeating: "x", count: 40), refreshToken: nil)
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

private final class InMemoryAuthSessionStore: AuthSessionStore, @unchecked Sendable {
    var savedUserID: String?

    func loadUserID() -> String? { savedUserID }

    func saveUserID(_ userID: String) throws {
        savedUserID = userID
    }

    func clear() throws {
        savedUserID = nil
    }
}

private final class InMemoryAPIAccessTokenStore: APIAccessTokenStore, @unchecked Sendable {
    var savedToken: String?

    func loadAccessToken() -> String? { savedToken }

    func saveAccessToken(_ token: String) throws {
        savedToken = token
    }

    func clearAccessToken() throws {
        savedToken = nil
    }
}
