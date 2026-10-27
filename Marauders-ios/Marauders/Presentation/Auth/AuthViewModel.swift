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

    /// Defaults to the country resolved from location; the user may override it before sign-in.
    /// Location permission and a successful lookup are still required by the sign-in gate.
    var selectedCountryCode: String = CountryCatalog.defaultCode()

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
            isSignedIn = !ProcessInfo.processInfo.arguments.contains("UITEST_GUEST")
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

        #if DEBUG
        // A simulator test user has no Apple credential to check; its access token is the only proof.
        if DevLogin.isDevUserID(userID) {
            isSignedIn = true
            return
        }
        #endif

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
            let accessToken = try await authAPI.exchangeAppleIdentityToken(
                identityToken,
                countryCode: selectedCountryCode
            )
            try sessionStore.saveUserID(userID)
            try tokenStore.saveAccessToken(accessToken)
            isSignedIn = true
            errorMessage = nil
            AppLog.info("auth", "signed in with Apple (API session established)")
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            if let statusCode = (error as? AuthAPIError)?.httpStatusCode {
                AppLog.error("auth", "API session exchange failed (status \(statusCode))")
            } else {
                AppLog.error("auth", "API session exchange failed")
            }
        }
    }

    #if DEBUG
    /// Simulator only: becomes the test user named by `DevLogin.label`, a different account from any Apple ID.
    func signInAsDevUser() async {
        guard let secret = DevLogin.secret else { return }
        let label = DevLogin.label
        do {
            let accessToken = try await DevAuthAPIClient().accessToken(
                secret: secret,
                label: label,
                countryCode: selectedCountryCode
            )
            try sessionStore.saveUserID(DevLogin.userIDPrefix + label)
            try tokenStore.saveAccessToken(accessToken)
            isSignedIn = true
            errorMessage = nil
            AppLog.info("auth", "signed in as dev user \(label)")
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            AppLog.error("auth", "dev sign in failed")
        }
    }

    /// UI-only completion; creates no credentials and never authenticates API requests.
    func completeUITestSignIn() {
        guard AppRuntimeConfiguration.isUITesting else { return }
        isSignedIn = true
        isCheckingCredential = false
    }
    #endif

    func signOut() {
        try? sessionStore.clear()
        try? tokenStore.clearAccessToken()
        isSignedIn = false
        errorMessage = nil
        AppLog.info("auth", "signed out")
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Sign in failed. Please try again."
    }

    private static func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
