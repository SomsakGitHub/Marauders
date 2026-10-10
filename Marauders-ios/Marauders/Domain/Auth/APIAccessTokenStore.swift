//
//  APIAccessTokenStore.swift
//  Marauders
//

import Foundation

/// Persists the Worker-issued access token (never log or expose in UI).
protocol APIAccessTokenStore: Sendable {
    func loadAccessToken() -> String?
    func saveAccessToken(_ token: String) throws
    func clearAccessToken() throws
}

enum APIAccessTokenFormat {
    static func isValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 8192 else { return false }
        return !trimmed.unicodeScalars.contains { $0.value < 32 }
    }
}
