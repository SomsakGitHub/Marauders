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

    init(sessionStore: AuthSessionStore = KeychainAuthSessionStore()) {
        self.sessionStore = sessionStore
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
              KeychainAuthSessionStore.isValidUserID(userID)
        else {
            isSignedIn = false
            return
        }

        let state = await Self.credentialState(for: userID)
        switch state {
        case .authorized:
            isSignedIn = true
        case .revoked, .notFound:
            try? sessionStore.clear()
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
            completeSignIn(userID: credential.user)
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

    func completeSignIn(userID: String) {
        guard KeychainAuthSessionStore.isValidUserID(userID) else {
            errorMessage = "Invalid account"
            return
        }
        do {
            try sessionStore.saveUserID(userID)
            isSignedIn = true
            errorMessage = nil
            AppLog.info("auth", "signed in with Apple")
        } catch {
            errorMessage = "Couldn’t save sign-in state"
            AppLog.error("auth", "failed to persist sign-in state")
        }
    }

    func signOut() {
        try? sessionStore.clear()
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
