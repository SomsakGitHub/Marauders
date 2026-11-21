//
//  AccountDeletionViewModel.swift
//  Marauders
//

import AuthenticationServices
import Foundation
import Observation

/// What the deletion sheet shows and does, from the first tap to the last word: Apple confirms that the person is the
/// owner, the Worker deletes the account, and the app lets the viewer go.
@MainActor
@Observable
final class AccountDeletionViewModel {
    enum Phase: Equatable {
        case idle
        case deleting
        /// The words the person is shown; they can try again from here.
        case failed(String)
        case deleted
    }

    private(set) var phase: Phase = .idle
    /// Runs once the account is gone and `phase` says so; the composition root has it end the session on this iPhone.
    /// A deletion that failed never runs it.
    @ObservationIgnored var onAccountDeleted: (@MainActor () async -> Void)?

    private let deleteAccount: DeleteAccountUseCase

    init(deleteAccount: DeleteAccountUseCase) {
        self.deleteAccount = deleteAccount
    }

    /// What Sign in with Apple's button reports. The credential holds the one-time authorization code that the Worker
    /// needs to have Apple revoke the person's tokens.
    func handleAuthorization(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential
            await handleAppleResult(.success(credential?.authorizationCode))
        case .failure(let error):
            await handleAppleResult(.failure(error))
        }
    }

    /// Apple's answer, as the code it gave (or none) or the reason it did not. A cancelled sheet takes the person back to
    /// the start quietly. Any other failure, and a code that cannot be used, is "Apple couldn't confirm it's you" and
    /// asks nothing of the Worker. A code starts the deletion. A deletion that is under way ignores any late answer.
    func handleAppleResult(_ result: Result<Data?, Error>) async {
        guard phase != .deleting else { return }
        switch result {
        case .success(let data):
            guard let data, let code = String(data: data, encoding: .utf8), !code.isEmpty else {
                fail(with: .appleNotConfirmed)
                return
            }
            await delete(authorizationCode: code)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
                nsError.code == ASAuthorizationError.canceled.rawValue
            {
                phase = .idle
            } else {
                fail(with: .appleNotConfirmed)
            }
        }
    }

    /// Deletes the account. A second call while the first runs does nothing, because an Apple code works once. The
    /// Debug-only buttons of a test user call it with no code.
    func delete(authorizationCode: String?) async {
        guard phase != .deleting else { return }
        phase = .deleting
        do {
            try await deleteAccount.execute(authorizationCode: authorizationCode)
        } catch {
            fail(with: error as? AccountDeletionError ?? .couldNotFinish)
            return
        }
        AppLog.info("account", "the account was deleted")
        phase = .deleted
        await onAccountDeleted?()
    }

    /// Back to the start, as the sheet is dismissed. A deletion that is under way is not undone by a dismissed sheet.
    func reset() {
        guard phase != .deleting else { return }
        phase = .idle
    }

    private func fail(with reason: AccountDeletionError) {
        AppLog.error("account", "deletion failed: \(reason)")
        phase = .failed(reason.localizedDescription)
    }
}
