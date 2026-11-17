//
//  APIAccessTokenStore.swift
//  Marauders
//

import Foundation

/// Persists the Worker-issued access token (never log or expose in UI).
public protocol APIAccessTokenStore: Sendable {
    func loadAccessToken() -> String?
    /// The stored access token, with a store that cannot be read right now told apart from one that holds nothing.
    /// `loadAccessToken()` answers nil to both.
    func readAccessToken() -> StoredCredential
    func saveAccessToken(_ token: String) throws
    func clearAccessToken() throws
}

extension APIAccessTokenStore {
    /// For a store that can always be read: no token means none is stored.
    public func readAccessToken() -> StoredCredential {
        loadAccessToken().map(StoredCredential.value) ?? .missing
    }
}

public nonisolated enum APIAccessTokenFormat {
    public static func isValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 8192 else { return false }
        return !trimmed.unicodeScalars.contains { $0.value < 32 }
    }
}
