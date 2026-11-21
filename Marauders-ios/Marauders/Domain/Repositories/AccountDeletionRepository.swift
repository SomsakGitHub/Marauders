//
//  AccountDeletionRepository.swift
//  Marauders
//

import Foundation

protocol AccountDeletionRepository: Sendable {
    /// Deletes the signed-in account and everything it owns. `authorizationCode` is the one-time code from the Sign in
    /// with Apple sheet the person just confirmed; a test account of the debug sign-in has none. Throws an
    /// `AccountDeletionError` for an answer of the Worker, and the transport's own error when it could not be reached.
    func deleteAccount(authorizationCode: String?) async throws
}
