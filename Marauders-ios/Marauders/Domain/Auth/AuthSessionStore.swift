//
//  AuthSessionStore.swift
//  Marauders
//

import Foundation

/// Persists the Apple Sign In user identifier (opaque ID only — no tokens in app storage).
protocol AuthSessionStore: Sendable {
    func loadUserID() -> String?
    func saveUserID(_ userID: String) throws
    func clear() throws
}

enum AuthUserID {
    /// A non-empty identifier of at most 512 characters, without control characters.
    static func isValid(_ userID: String) -> Bool {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return false }
        return !trimmed.unicodeScalars.contains { $0.value < 32 }
    }
}
