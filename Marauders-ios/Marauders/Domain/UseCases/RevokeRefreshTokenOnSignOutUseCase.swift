//
//  RevokeRefreshTokenOnSignOutUseCase.swift
//  Marauders
//

import Foundation

/// Tells the Worker the viewer's session is over as they sign out, by revoking the refresh token's whole family there.
/// Without it a copy of the token that outlived the sign out (a backup, a device that was stolen before the app was
/// deleted) could still be traded for a session until it expires.
///
/// Best effort, like the sharing call it runs after: it never throws and never waits longer than the time it is given,
/// so the sign out is never held back by it. A viewer who is offline keeps a token the Worker still accepts until it
/// expires; the app has dropped its copy either way.
struct RevokeRefreshTokenOnSignOutUseCase {
    enum Outcome: Equatable, Sendable {
        /// The Worker revoked the token's family.
        case revoked
        /// No refresh token is stored (a session from before refresh tokens existed): nothing was asked.
        case nothingToRevoke
        /// The call went wrong; `reason` is for the log and never holds the token.
        case failed(reason: String)
        /// No answer in time; the call was given up.
        case timedOut
    }

    private let authAPI: any AuthAPIClientProtocol
    private let refreshTokenStore: any APIRefreshTokenStore

    init(authAPI: any AuthAPIClientProtocol, refreshTokenStore: any APIRefreshTokenStore) {
        self.authAPI = authAPI
        self.refreshTokenStore = refreshTokenStore
    }

    /// Reads the stored token when it runs, not when the use case was made: the call before it may have swapped the
    /// token for a newer one.
    func execute(within timeout: Duration) async -> Outcome {
        guard let refreshToken = refreshTokenStore.loadRefreshToken() else { return .nothingToRevoke }
        let authAPI = authAPI
        switch await TimeBoundedCall.run(timeout: timeout, { try await authAPI.revokeRefreshToken(refreshToken) }) {
        case .finished:
            return .revoked
        case .failed(let reason):
            return .failed(reason: reason)
        case .timedOut:
            return .timedOut
        }
    }
}
