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

    init(
        authAPI: any AuthAPIClientProtocol,
        sessionStore: any AuthSessionStore,
        tokenStore: any APIAccessTokenStore
    ) {
        self.authAPI = authAPI
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
    }

    func execute(userID: String, identityToken: String, countryCode: String) async throws {
        guard AuthUserID.isValid(userID) else { throw SignInError.invalidAccount }
        let accessToken = try await authAPI.exchangeAppleIdentityToken(identityToken, countryCode: countryCode)
        try sessionStore.saveUserID(userID)
        try tokenStore.saveAccessToken(accessToken)
    }
}

#if DEBUG
    /// Simulator only: becomes a named test user instead of an Apple account.
    struct SignInAsDevUserUseCase {
        private let devAuth: any DevAuthExchanging
        private let sessionStore: any AuthSessionStore
        private let tokenStore: any APIAccessTokenStore

        init(
            devAuth: any DevAuthExchanging,
            sessionStore: any AuthSessionStore,
            tokenStore: any APIAccessTokenStore
        ) {
            self.devAuth = devAuth
            self.sessionStore = sessionStore
            self.tokenStore = tokenStore
        }

        func execute(secret: String, label: String, userID: String, countryCode: String) async throws {
            let accessToken = try await devAuth.accessToken(secret: secret, label: label, countryCode: countryCode)
            try sessionStore.saveUserID(userID)
            try tokenStore.saveAccessToken(accessToken)
        }
    }
#endif
