//
//  APIAccessTokenExpiry.swift
//  Marauders
//

import Foundation

/// Reads the `exp` claim of the Worker's access token (an HS256 JWT) on the device.
///
/// This only keeps the app from presenting a session that has certainly ended; the Worker verifies the token on every
/// request (see `APIAccessTokenPayload`).
public nonisolated enum APIAccessTokenExpiry {
    /// When the token expires, or nil when it is not a JWT or its payload has no numeric `exp`.
    static func expirationDate(of token: String) -> Date? {
        guard let claims = APIAccessTokenPayload.claims(of: token, as: Claims.self) else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    /// True once `exp` is no later than `now`, and also when it cannot be read: a token that cannot be dated is
    /// treated like a missing one.
    public static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expirationDate(of: token) else { return true }
        return expiry <= now
    }

    private nonisolated struct Claims: Decodable {
        /// Seconds since 1970, which JWT allows to be fractional.
        let exp: TimeInterval
    }
}
