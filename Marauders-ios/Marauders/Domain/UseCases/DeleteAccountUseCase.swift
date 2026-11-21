//
//  DeleteAccountUseCase.swift
//  Marauders
//

import Foundation

/// Deletes the signed-in account on the Worker and then clears the feed this iPhone saved for it. The Worker goes first:
/// a deletion that failed leaves the account, and its saved feed stays for the next try.
struct DeleteAccountUseCase: Sendable {
    private let repository: AccountDeletionRepository
    private let feedCache: FeedStartupCacheClearing?

    init(repository: AccountDeletionRepository, feedCache: FeedStartupCacheClearing?) {
        self.repository = repository
        self.feedCache = feedCache
    }

    func execute(authorizationCode: String?) async throws {
        try await repository.deleteAccount(authorizationCode: authorizationCode)
        await feedCache?.removeAll()
    }
}
