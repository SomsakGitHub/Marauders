//
//  AuthViewModelTests.swift
//  MaraudersTests
//

import Testing
@testable import Marauders

@MainActor
struct AuthViewModelTests {
    @Test func completeSignInPersistsUserAndAccessToken() async {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            authAPI: StubAuthAPIClient()
        )

        await viewModel.completeSignIn(userID: "001234.abcdef.5678", identityToken: String(repeating: "a", count: 32))

        #expect(viewModel.isSignedIn)
        #expect(store.savedUserID == "001234.abcdef.5678")
        #expect(tokenStore.savedToken == StubAuthAPIClient.stubToken)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func completeSignInRejectsEmptyUserID() async {
        let store = InMemoryAuthSessionStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: InMemoryAPIAccessTokenStore(),
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

    @Test func signOutClearsSessionAndToken() async {
        let store = InMemoryAuthSessionStore()
        let tokenStore = InMemoryAPIAccessTokenStore()
        let viewModel = AuthViewModel(
            sessionStore: store,
            tokenStore: tokenStore,
            authAPI: StubAuthAPIClient()
        )
        await viewModel.completeSignIn(userID: "user-1", identityToken: String(repeating: "b", count: 32))

        viewModel.signOut()

        #expect(!viewModel.isSignedIn)
        #expect(store.savedUserID == nil)
        #expect(tokenStore.savedToken == nil)
    }
}

private struct StubAuthAPIClient: AuthAPIClientProtocol {
    static let stubToken = String(repeating: "x", count: 40)

    func exchangeAppleIdentityToken(_ identityToken: String) async throws -> String {
        Self.stubToken
    }
}

private struct FailingAuthAPIClient: AuthAPIClientProtocol {
    let error: AuthAPIError

    func exchangeAppleIdentityToken(_ identityToken: String) async throws -> String {
        throw error
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
