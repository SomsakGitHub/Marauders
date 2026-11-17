//
//  AuthSessionStore.swift
//  Marauders
//

import Foundation

/// Persists the Apple Sign In user identifier (opaque ID only — no tokens in app storage).
public protocol AuthSessionStore: Sendable {
    func loadUserID() -> String?
    /// The stored user ID, with a store that cannot be read right now told apart from one that holds nothing.
    /// `loadUserID()` answers nil to both.
    func readUserID() -> StoredCredential
    func saveUserID(_ userID: String) throws
    func clear() throws
}

extension AuthSessionStore {
    /// For a store that can always be read: no user ID means none is stored.
    public func readUserID() -> StoredCredential {
        loadUserID().map(StoredCredential.value) ?? .missing
    }
}

public enum AuthUserID {
    /// A non-empty identifier of at most 512 characters, without control characters.
    public static func isValid(_ userID: String) -> Bool {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return false }
        return !trimmed.unicodeScalars.contains { $0.value < 32 }
    }
}
