//
//  AuthViewModel.swift
//  Marauders
//

import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class AuthViewModel {
    private(set) var isSignedIn = false
    private(set) var isCheckingCredential = true
    var errorMessage: String?

    private let sessionStore: AuthSessionStore
    private let tokenStore: APIAccessTokenStore
    private let authAPI: AuthAPIClientProtocol

    init(
        sessionStore: AuthSessionStore = KeychainAuthSessionStore(),
        tokenStore: APIAccessTokenStore = KeychainAPIAccessTokenStore(),
        authAPI: AuthAPIClientProtocol = AuthAPIClient()
    ) {
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.authAPI = authAPI
        if AppRuntimeConfiguration.isUITesting {
            isSignedIn = true
            isCheckingCredential = false
        }
    }

    func restoreSession() async {
        if AppRuntimeConfiguration.isUITesting {
            isCheckingCredential = false
            return
        }

        defer { isCheckingCredential = false }

        guard let userID = sessionStore.loadUserID(),
              KeychainAuthSessionStore.isValidUserID(userID),
              let accessToken = tokenStore.loadAccessToken(),
              APIAccessTokenFormat.isValid(accessToken)
        else {
            try? sessionStore.clear()
            try? tokenStore.clearAccessToken()
            isSignedIn = false
            return
        }

        let state = await Self.credentialState(for: userID)
        switch state {
        case .authorized:
            isSignedIn = true
        case .revoked, .notFound:
            try? sessionStore.clear()
            try? tokenStore.clearAccessToken()
            isSignedIn = false
        case .transferred:
            isSignedIn = false
        @unknown default:
            isSignedIn = false
        }
    }

    func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Sign in failed"
                return
            }
            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                errorMessage = "Sign in failed"
                return
            }
            Task {
                await completeSignIn(userID: credential.user, identityToken: identityToken)
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue
            {
                return
            }
            errorMessage = "Sign in was not completed"
            AppLog.error("auth", "Apple sign in failed")
        }
    }

    func completeSignIn(userID: String, identityToken: String) async {
        guard KeychainAuthSessionStore.isValidUserID(userID) else {
            errorMessage = "Invalid account"
            return
        }

        do {
            let accessToken = try await authAPI.exchangeAppleIdentityToken(identityToken)
            try sessionStore.saveUserID(userID)
            try tokenStore.saveAccessToken(accessToken)
            isSignedIn = true
            errorMessage = nil
            AppLog.info("auth", "signed in with Apple (API session established)")
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("auth", "API session exchange failed")
        }
    }

    func signOut() {
        try? sessionStore.clear()
        try? tokenStore.clearAccessToken()
        isSignedIn = false
        errorMessage = nil
        AppLog.info("auth", "signed out")
    }

    private static func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
