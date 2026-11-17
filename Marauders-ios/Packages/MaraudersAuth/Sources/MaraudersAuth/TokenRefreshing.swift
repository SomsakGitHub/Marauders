//
//  TokenRefreshing.swift
//  Marauders
//

import Foundation

/// What asking for a new access token came to, for the request that met the 401.
public nonisolated enum TokenRefreshOutcome: Sendable {
    /// The session goes on with this access token: one the Worker just issued, or one an earlier refresh had stored.
    case refreshed(String)
    /// The session cannot be renewed: there is nothing to renew it with, the Worker refused the refresh token, or the
    /// session the answer was for is no longer the stored one. Ending the session is up to the caller.
    case rejected
    /// The Worker could not be asked or did not answer. Nothing is known about the session, so it is kept as it is.
    case unavailable(any Error)
}

/// Trades an access token the Worker rejected for one that works.
public nonisolated protocol TokenRefreshing: Sendable {
    /// A token to use instead of `rejectedAccessToken`, which the Worker answered with 401.
    func refreshedAccessToken(replacing rejectedAccessToken: String) async -> TokenRefreshOutcome
}
