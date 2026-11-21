//
//  UITestAccountDeletionRepository.swift
//  Marauders
//

import Foundation

/// A deletion for UI tests — no network. It takes a moment, so the progress is on screen, and then it succeeds or, when
/// `fails` is set, answers that it could not finish.
final class UITestAccountDeletionRepository: AccountDeletionRepository, @unchecked Sendable {
    private let fails: Bool

    init(fails: Bool) {
        self.fails = fails
    }

    func deleteAccount(authorizationCode: String?) async throws {
        try await Task.sleep(for: .milliseconds(300))
        if fails {
            throw AccountDeletionError.couldNotFinish
        }
    }
}
