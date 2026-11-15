//
//  SignInWithAppleUseCase.swift
//  Marauders
//

import Foundation

enum SignInError: LocalizedError, Equatable {
    case invalidAccount

    var errorDescription: String? { "Invalid account" }
}

/// Trades an Apple identity token for a Worker session and keeps the session once it is established.
struct SignInWithAppleUseCase {
    private let authAPI: any AuthAPIClientProtocol
    private let sessionStore: any AuthSessionStore
    private let tokenStore: any APIAccessTokenStore
    private let refreshTokenStore: any APIRefreshTokenStore

    init(
        authAPI: any AuthAPIClientProtocol,
        sessionStore: any AuthSessionStore,
        tokenStore: any APIAccessTokenStore,
        refreshTokenStore: any APIRefreshTokenStore
    ) {
        self.authAPI = authAPI
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.refreshTokenStore = refreshTokenStore
    }

    func execute(userID: String, identityToken: String, countryCode: String) async throws {
        guard AuthUserID.isValid(userID) else { throw SignInError.invalidAccount }
        let tokens = try await authAPI.exchangeAppleIdentityToken(identityToken, countryCode: countryCode)
        try saveSession(
            userID: userID, tokens: tokens,
            sessionStore: sessionStore, tokenStore: tokenStore, refreshTokenStore: refreshTokenStore)
    }
}

#if DEBUG
    /// Simulator only: becomes a named test user instead of an Apple account.
    struct SignInAsDevUserUseCase {
        private let devAuth: any DevAuthExchanging
        private let sessionStore: any AuthSessionStore
        private let tokenStore: any APIAccessTokenStore
        private let refreshTokenStore: any APIRefreshTokenStore

        init(
            devAuth: any DevAuthExchanging,
            sessionStore: any AuthSessionStore,
            tokenStore: any APIAccessTokenStore,
            refreshTokenStore: any APIRefreshTokenStore
        ) {
            self.devAuth = devAuth
            self.sessionStore = sessionStore
            self.tokenStore = tokenStore
            self.refreshTokenStore = refreshTokenStore
        }

        func execute(secret: String, label: String, userID: String, countryCode: String) async throws {
            let tokens = try await devAuth.tokens(secret: secret, label: label, countryCode: countryCode)
            try saveSession(
                userID: userID, tokens: tokens,
                sessionStore: sessionStore, tokenStore: tokenStore, refreshTokenStore: refreshTokenStore)
        }
    }
#endif

/// Keeps the session a sign-in opened: the user, then the refresh token (an answer without one clears what an earlier
/// session left behind), then the access token. A save that fails stops it there and nothing after it is written.
///
/// There is no `await` between the saves. The token refresher reads and writes these stores on the main actor too, so
/// it can never run in the middle and find half a session.
private func saveSession(
    userID: String,
    tokens: AuthTokens,
    sessionStore: any AuthSessionStore,
    tokenStore: any APIAccessTokenStore,
    refreshTokenStore: any APIRefreshTokenStore
) throws {
    try sessionStore.saveUserID(userID)
    if let refreshToken = tokens.refreshToken {
        try refreshTokenStore.saveRefreshToken(refreshToken)
    } else {
        try refreshTokenStore.clearRefreshToken()
    }
    try tokenStore.saveAccessToken(tokens.accessToken)
}
