//
//  APIAccessTokenExpiry.swift
//  Marauders
//

import Foundation

/// Reads the `exp` claim of the Worker's access token (an HS256 JWT) on the device.
///
/// Only the payload is decoded. The device holds no signing key and checks nothing else; the Worker verifies the
/// signature on every request. This only keeps the app from presenting a session that has certainly ended.
nonisolated enum APIAccessTokenExpiry {
    /// When the token expires, or nil when it is not a JWT or its payload has no numeric `exp`.
    static func expirationDate(of token: String) -> Date? {
        let segments = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = base64URLDecoded(String(segments[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload)
        else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    /// True once `exp` is no later than `now`, and also when it cannot be read: a token that cannot be dated is
    /// treated like a missing one.
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expirationDate(of: token) else { return true }
        return expiry <= now
    }

    private nonisolated struct Claims: Decodable {
        /// Seconds since 1970, which JWT allows to be fractional.
        let exp: TimeInterval
    }

    private static func base64URLDecoded(_ segment: String) -> Data? {
        guard !segment.isEmpty else { return nil }
        let base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64 + padding)
    }
}
