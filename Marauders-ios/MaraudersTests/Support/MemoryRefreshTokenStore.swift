//
//  MemoryRefreshTokenStore.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders
@testable import MaraudersAuth

/// An in-memory `APIRefreshTokenStore`. Setting `saveError` or `clearError` makes that call throw, and the token is
/// left as it was, the way a Keychain write that fails leaves it.
nonisolated final class MemoryRefreshTokenStore: APIRefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var failingSave: (any Error)?
    private var failingClear: (any Error)?

    init(token: String? = nil) {
        stored = token
    }

    var token: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var saveError: (any Error)? {
        get { lock.withLock { failingSave } }
        set { lock.withLock { failingSave = newValue } }
    }

    var clearError: (any Error)? {
        get { lock.withLock { failingClear } }
        set { lock.withLock { failingClear = newValue } }
    }

    func loadRefreshToken() -> String? { token }

    func saveRefreshToken(_ token: String) throws {
        if let error = saveError { throw error }
        self.token = token
    }

    func clearRefreshToken() throws {
        if let error = clearError { throw error }
        token = nil
    }
}
