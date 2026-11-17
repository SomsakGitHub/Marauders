//
//  APIRefreshTokenStore.swift
//  Marauders
//

import Foundation

/// Persists the Worker-issued refresh token, the long-lived credential that buys a new access token (never log or
/// expose in UI). It is kept apart from the access token so each can be saved and cleared on its own.
public protocol APIRefreshTokenStore: Sendable {
    func loadRefreshToken() -> String?
    func saveRefreshToken(_ token: String) throws
    func clearRefreshToken() throws
}

/// The shape of a refresh token. The Worker hands out 32 random bytes as 43 base64url characters; the range around
/// that is wide on purpose, so a longer token from a later Worker still fits and a truncated or padded one does not.
public nonisolated enum APIRefreshTokenFormat {
    public static func isValid(_ token: String) -> Bool {
        guard (32...256).contains(token.utf8.count) else { return false }
        return token.unicodeScalars.allSatisfy(isBase64URLCharacter)
    }

    private static func isBase64URLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
            return true
        default:
            return false
        }
    }
}
