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
    private(set) var isSigningOut = false
    var errorMessage: String?

    /// Switches the viewer's location sharing off on the Worker when they sign out. The composition root sets it once
    /// the repositories exist: they talk through a transport that reports a rejected token back to this view model.
    @ObservationIgnored var stopSharingOnSignOut: StopLocationSharingOnSignOutUseCase?

    /// Defaults to the country resolved from location; the user may override it before sign-in.
    /// Location permission and a successful lookup are still required by the sign-in gate.
    var selectedCountryCode: String = CountryCatalog.defaultCode()

    /// What Apple says about the account behind a saved session; replaced in tests.
    typealias CredentialStateProvider = @Sendable (String) async -> ASAuthorizationAppleIDProvider.CredentialState

    private let sessionStore: AuthSessionStore
    private let tokenStore: APIAccessTokenStore
    private let refreshTokenStore: APIRefreshTokenStore
    private let signInWithApple: SignInWithAppleUseCase
    #if DEBUG
        private let signInAsDevUserUseCase: SignInAsDevUserUseCase?
    #endif
    private let credentialState: CredentialStateProvider
    /// Debug Simulator builds with a dev login secret: no session means becoming the test user, until a sign out.
    private var signsInAsTestUserOnSimulator: Bool
    /// Moves whenever the stored session is ended or replaced: a sign out, a rejection, a new sign in. A refresh never
    /// moves it, because that renews the session that is stored. `restoreSession()` compares it across Apple's answer
    /// to tell whether the answer is still about the stored session.
    @ObservationIgnored private var sessionGeneration = 0

    init(
        sessionStore: AuthSessionStore,
        tokenStore: APIAccessTokenStore,
        refreshTokenStore: APIRefreshTokenStore,
        authAPI: AuthAPIClientProtocol,
        devAuth: (any DevAuthExchanging)? = nil,
        credentialState: @escaping CredentialStateProvider = AuthViewModel.appleCredentialState,
        signsInAsTestUserOnSimulator: Bool = false
    ) {
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.refreshTokenStore = refreshTokenStore
        self.signInWithApple = SignInWithAppleUseCase(
            authAPI: authAPI, sessionStore: sessionStore, tokenStore: tokenStore, refreshTokenStore: refreshTokenStore)
        #if DEBUG
            self.signInAsDevUserUseCase = devAuth.map {
                SignInAsDevUserUseCase(
                    devAuth: $0, sessionStore: sessionStore, tokenStore: tokenStore,
                    refreshTokenStore: refreshTokenStore)
            }
        #endif
        self.credentialState = credentialState
        self.signsInAsTestUserOnSimulator = signsInAsTestUserOnSimulator
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

        // A token past its `exp`, or one whose `exp` cannot be read, is a session that has ended: the Worker would
        // answer 401 to it. It is treated like a missing token, unless a refresh token is stored. Then the first
        // request that meets the 401 trades it for a new access token and the session lives on. Nothing is refreshed
        // here: opening the app asks the Worker nothing.
        guard let userID = sessionStore.loadUserID(),
            AuthUserID.isValid(userID),
            let accessToken = tokenStore.loadAccessToken(),
            APIAccessTokenFormat.isValid(accessToken),
            !APIAccessTokenExpiry.isExpired(accessToken) || hasUsableRefreshToken
        else {
            clearStoredSession()
            isSignedIn = false
            #if DEBUG
                if signsInAsTestUserOnSimulator && DevLogin.isAvailable {
                    // Once: a failure leaves the sign-in screen and its test user button, not a retry on every tab.
                    signsInAsTestUserOnSimulator = false
                    await signInAsDevUser()
                }
            #endif
            return
        }

        #if DEBUG
            // A simulator test user has no Apple credential to check; its access token is the only proof.
            if DevLogin.isDevUserID(userID) {
                isSignedIn = true
                return
            }
        #endif

        let generation = sessionGeneration
        let state = await credentialState(userID)
        // The Worker may have rejected this session, or the viewer signed out or in again, while Apple was answering.
        // The answer is about a session that is gone then: it must not bring it back, and must not wipe the new one.
        // A refresh in the meantime changes the tokens but not the session, so it does not count.
        guard sessionGeneration == generation else { return }
        switch state {
        case .authorized:
            isSignedIn = true
        case .revoked, .notFound:
            clearStoredSession()
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
        do {
            try await signInWithApple.execute(
                userID: userID, identityToken: identityToken, countryCode: selectedCountryCode)
            sessionGeneration += 1
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
            guard let secret = DevLogin.secret, let useCase = signInAsDevUserUseCase else { return }
            let label = DevLogin.label
            do {
                try await useCase.execute(
                    secret: secret,
                    label: label,
                    userID: DevLogin.userIDPrefix + label,
                    countryCode: selectedCountryCode
                )
                sessionGeneration += 1
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

    /// Ends the session the viewer asked to end. Their location sharing is switched off on the Worker first, while the
    /// token still works, so their last location stops showing on their mutual followers' maps; that call is best
    /// effort and never holds the sign out back. A session that ended without this (the Worker rejected the token, or it
    /// ran out) goes through `handleRejectedAccessToken` or `restoreSession` instead and cannot make the call.
    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        // A Simulator test user who signs out stays out until the app is launched again.
        signsInAsTestUserOnSimulator = false
        if isSignedIn { await switchLocationSharingOff() }
        clearStoredSession()
        isSignedIn = false
        errorMessage = nil
        AppLog.info("auth", "signed out")
    }

    private func switchLocationSharingOff() async {
        guard let stopSharingOnSignOut else { return }
        switch await stopSharingOnSignOut.execute() {
        case .switchedOff:
            AppLog.info("auth", "location sharing switched off before sign out")
        case .failed(let reason):
            AppLog.warning("auth", "location sharing not switched off before sign out: \(reason)")
        case .timedOut:
            AppLog.warning("auth", "location sharing not switched off before sign out: no answer in time")
        }
    }

    /// The Worker answered 401 to a request that carried `accessToken`. When that is still the stored token the
    /// session has ended on the server, so it ends here as well, like a sign out: the stored session and token go and
    /// `isSignedIn` turns false, which brings up the sign-in gates that lead to the shared sign-in screen. A token that
    /// is no longer the stored one belongs to a session that was already ended or replaced by a newer sign-in, so a
    /// late answer to a request from before it changes nothing.
    func handleRejectedAccessToken(_ accessToken: String) {
        guard tokenStore.loadAccessToken() == accessToken else { return }
        clearStoredSession()
        isSignedIn = false
        AppLog.warning("auth", "access token rejected by the Worker, signed out")
    }

    private func clearStoredSession() {
        sessionGeneration += 1
        try? sessionStore.clear()
        try? tokenStore.clearAccessToken()
        try? refreshTokenStore.clearRefreshToken()
    }

    /// A refresh token of the shape the Worker issues is stored. Whether the Worker still accepts it is for the refresh
    /// itself to find out.
    private var hasUsableRefreshToken: Bool {
        refreshTokenStore.loadRefreshToken().map(APIRefreshTokenFormat.isValid) ?? false
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Sign in failed. Please try again."
    }

    nonisolated static func appleCredentialState(for userID: String) async
        -> ASAuthorizationAppleIDProvider.CredentialState
    {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
