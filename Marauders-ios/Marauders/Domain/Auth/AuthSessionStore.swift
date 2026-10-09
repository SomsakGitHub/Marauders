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
