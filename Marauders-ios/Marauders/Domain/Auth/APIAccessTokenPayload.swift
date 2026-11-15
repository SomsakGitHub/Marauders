//
//  APIAccessTokenPayload.swift
//  Marauders
//

import Foundation

/// Reads claims out of the Worker's access token (an HS256 JWT) on the device.
///
/// Only the payload is decoded. The device holds no signing key and checks nothing else; the Worker verifies the
/// signature on every request. What the device reads is for its own bookkeeping: whether a session has certainly ended
/// (`APIAccessTokenExpiry`) and whose it is (`APIAccessTokenSubject`).
nonisolated enum APIAccessTokenPayload {
    /// The payload of `token` as `Claims`, or nil when the token is not a JWT or its payload does not hold them.
    static func claims<Claims: Decodable>(of token: String, as type: Claims.Type) -> Claims? {
        let segments =
            token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = base64URLDecoded(String(segments[1])) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: payload)
    }

    private static func base64URLDecoded(_ segment: String) -> Data? {
        guard !segment.isEmpty else { return nil }
        let base64 =
            segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64 + padding)
    }
}
