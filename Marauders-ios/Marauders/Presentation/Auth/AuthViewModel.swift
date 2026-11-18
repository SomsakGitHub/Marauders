//
//  AuthViewModel.swift
//  Marauders
//

import AuthenticationServices
import Foundation
import MaraudersAuth
import Observation

@MainActor
@Observable
final class AuthViewModel {
    private(set) var isSignedIn = false
    private(set) var isCheckingCredential = true
    private(set) var isSigningOut = false
    /// The last `restoreSession()` could not read the stored session, so it decided nothing: the session was neither
    /// brought back nor ended. That is the Keychain between a restart of the iPhone and its first unlock, when iOS can
    /// already have launched the app in the background. `ContentView` asks again when the app comes to the foreground.
    private(set) var storedSessionIsUnavailable = false
    var errorMessage: String?

    /// Switches the viewer's location sharing off on the Worker when they sign out. The composition root sets it once
    /// the repositories exist: they talk through a transport that reports a rejected token back to this view model.
    @ObservationIgnored var stopSharingOnSignOut: StopLocationSharingOnSignOutUseCase?

    /// Drops the viewer's pending upload (its clip, its record and its task) when they sign out, so nothing of the
    /// account stays on the phone. The composition root sets it once the uploader exists.
    @ObservationIgnored var discardUploadOnSignOut: DiscardClipUploadUseCase?

    /// Lets the uploader check its stored upload against the account that has just signed in, before the viewer is
    /// signed in, so a clip of another account is never sent under the new one. Set together with
    /// `discardUploadOnSignOut`.
    @ObservationIgnored var checkUploadOnSignIn: ReconcileClipUploadUseCase?

    /// The longest a sign out waits to drop the upload, and a sign in waits to check it. A stuck uploader never holds
    /// either one back for longer than this.
    @ObservationIgnored var uploadHookTimeout: Duration = .seconds(3)

    /// Defaults to the country resolved from location; the user may override it before sign-in.
    /// Location permission and a successful lookup are still required by the sign-in gate.
    var selectedCountryCode: String = CountryCatalog.defaultCode()

    /// What Apple says about the account behind a saved session; replaced in tests.
    typealias CredentialStateProvider = @Sendable (String) async -> ASAuthorizationAppleIDProvider.CredentialState

    private let sessionStore: AuthSessionStore
    private let tokenStore: APIAccessTokenStore
    private let refreshTokenStore: APIRefreshTokenStore
    private let signInWithApple: SignInWithAppleUseCase
    private let revokeRefreshTokenOnSignOut: RevokeRefreshTokenOnSignOutUseCase
    /// How long a sign out waits for the Worker in all: the location sharing call and the refresh token revoke share it.
    private let signOutWindow: Duration
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
        signsInAsTestUserOnSimulator: Bool = false,
        signOutWindow: Duration = StopLocationSharingOnSignOutUseCase.defaultTimeout
    ) {
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.refreshTokenStore = refreshTokenStore
        self.signOutWindow = signOutWindow
        self.signInWithApple = SignInWithAppleUseCase(
            authAPI: authAPI, sessionStore: sessionStore, tokenStore: tokenStore, refreshTokenStore: refreshTokenStore)
        self.revokeRefreshTokenOnSignOut = RevokeRefreshTokenOnSignOutUseCase(
            authAPI: authAPI, refreshTokenStore: refreshTokenStore)
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

        let userID: String
        switch storedSession() {
        case .usable(let storedUserID):
            storedSessionIsUnavailable = false
            userID = storedUserID
        case .unavailable:
            // Nothing is cleared and nothing is decided: a viewer who is signed in stays so, and the next call asks
            // again.
            if !storedSessionIsUnavailable {
                AppLog.warning("auth", "stored session cannot be read right now, left as it is")
            }
            storedSessionIsUnavailable = true
            return
        case .ended:
            storedSessionIsUnavailable = false
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
                errorMessage = String(localized: "Sign in failed")
                return
            }
            guard let identityTokenData = credential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                errorMessage = String(localized: "Sign in failed")
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
            errorMessage = String(localized: "Sign in was not completed")
            AppLog.error("auth", "Apple sign in failed")
        }
    }

    func completeSignIn(userID: String, identityToken: String) async {
        do {
            try await signInWithApple.execute(
                userID: userID, identityToken: identityToken, countryCode: selectedCountryCode)
            sessionGeneration += 1
            await checkTheStoredUpload()
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

    /// Asks the uploader to check its stored upload against the session that was just stored: a clip of another account
    /// is deleted there, never to be sent under this one. It runs before `isSignedIn` turns true, so the viewer cannot
    /// try an upload that is not theirs. Best effort: a sign in is never held back for longer than `uploadHookTimeout`.
    private func checkTheStoredUpload() async {
        guard let check = checkUploadOnSignIn else { return }
        switch await TimeBoundedCall.run(timeout: uploadHookTimeout, { await check.execute() }) {
        case .finished:
            break
        case .failed(let reason):
            AppLog.warning("auth", "upload not checked before sign in: \(reason)")
        case .timedOut:
            AppLog.warning("auth", "upload not checked before sign in: no answer in time")
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
                await checkTheStoredUpload()
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

    /// Ends the session the viewer asked to end. The Worker is told first, while the tokens still work: their location
    /// sharing is switched off, so their last location stops showing on their mutual followers' maps, and then their
    /// refresh token is revoked, so no copy of it can be traded for a session again. Both calls are best effort, share
    /// one `signOutWindow` and never hold the sign out back. A session that ended without this (the Worker rejected the
    /// token, or it ran out) goes through `handleRejectedAccessToken` or `restoreSession` instead and cannot make them.
    ///
    /// Then the viewer's pending upload is dropped, signed in or not, so nothing of the account stays on the phone. A
    /// session that ended without a sign out keeps its upload: the same account can sign in again and try it again.
    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        // A Simulator test user who signs out stays out until the app is launched again.
        signsInAsTestUserOnSimulator = false
        if isSignedIn { await tellTheWorkerTheSessionIsEnding() }
        await discardThePendingUpload()
        clearStoredSession()
        isSignedIn = false
        errorMessage = nil
        AppLog.info("auth", "signed out")
    }

    private func tellTheWorkerTheSessionIsEnding() async {
        let clock = ContinuousClock()
        let started = clock.now
        await switchLocationSharingOff()
        let remaining = signOutWindow - started.duration(to: clock.now)
        guard remaining > .zero else {
            // Only worth a line for a session that has something to revoke.
            if refreshTokenStore.loadRefreshToken() != nil {
                AppLog.warning("auth", "refresh token not revoked before sign out: no time left")
            }
            return
        }
        await revokeRefreshToken(within: remaining)
    }

    private func revokeRefreshToken(within timeout: Duration) async {
        switch await revokeRefreshTokenOnSignOut.execute(within: timeout) {
        case .revoked:
            AppLog.info("auth", "refresh token revoked before sign out")
        case .nothingToRevoke:
            break
        case .failed(let reason):
            AppLog.warning("auth", "refresh token not revoked before sign out: \(reason)")
        case .timedOut:
            AppLog.warning("auth", "refresh token not revoked before sign out: no answer in time")
        }
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

    /// Best effort, like the two calls to the Worker: a stuck uploader never holds the sign out back for longer than
    /// `uploadHookTimeout`.
    private func discardThePendingUpload() async {
        guard let discard = discardUploadOnSignOut else { return }
        switch await TimeBoundedCall.run(timeout: uploadHookTimeout, { await discard.execute() }) {
        case .finished:
            break
        case .failed(let reason):
            AppLog.warning("auth", "upload not discarded before sign out: \(reason)")
        case .timedOut:
            AppLog.warning("auth", "upload not discarded before sign out: no answer in time")
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

    /// What `restoreSession()` finds stored.
    private enum StoredSession {
        /// A session that can be brought back, and the account it belongs to.
        case usable(userID: String)
        /// Nothing that can be brought back: a part is missing or malformed, or the access token has run out with no
        /// refresh token to renew it.
        case ended
        /// A part of it could not be read right now, so nothing is known about it.
        case unavailable
    }

    /// Reads the stored session.
    ///
    /// A token past its `exp`, or one whose `exp` cannot be read, is a session that has ended: the Worker would answer
    /// 401 to it. It is treated like a missing token, unless a refresh token of the shape the Worker issues is stored
    /// (whether the Worker still accepts it is for the refresh itself to find out). Then the first request that meets
    /// the 401 trades it for a new access token and the session lives on. Nothing is refreshed here: opening the app
    /// asks the Worker nothing.
    ///
    /// A part that cannot be read is not a part that is missing: from a restart of the iPhone until its first unlock
    /// the Keychain answers no read although the session is in it. Only the parts the answer depends on are read.
    private func storedSession() -> StoredSession {
        let storedUserID = sessionStore.readUserID()
        let storedAccessToken = tokenStore.readAccessToken()
        if storedUserID == .unavailable || storedAccessToken == .unavailable { return .unavailable }
        guard case .value(let userID) = storedUserID, AuthUserID.isValid(userID),
            case .value(let accessToken) = storedAccessToken, APIAccessTokenFormat.isValid(accessToken)
        else { return .ended }
        guard APIAccessTokenExpiry.isExpired(accessToken) else { return .usable(userID: userID) }

        switch refreshTokenStore.readRefreshToken() {
        case .value(let refreshToken):
            return APIRefreshTokenFormat.isValid(refreshToken) ? .usable(userID: userID) : .ended
        case .missing:
            return .ended
        case .unavailable:
            return .unavailable
        }
    }

    /// The text for a sign-in that failed, in the app's language. The session package keeps its texts in English and
    /// has no string catalog, so each of its errors gets the app's own text here; any other error that describes
    /// itself keeps its description.
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case AuthAPIError.invalidIdentityToken:
            return String(localized: "Sign in could not be verified")
        case AuthAPIError.invalidResponse:
            return String(localized: "Invalid sign-in response")
        case AuthAPIError.refreshRejected:
            return String(localized: "Your session has ended. Please sign in again.")
        case AuthAPIError.serverError(500...599):
            return String(localized: "The service is temporarily unavailable. Please try again.")
        case is AuthAPIError:
            return String(localized: "Sign in failed. Please try again.")
        case SignInError.invalidAccount:
            return String(localized: "Invalid account")
        default:
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                return description
            }
            return String(localized: "Sign in failed. Please try again.")
        }
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
