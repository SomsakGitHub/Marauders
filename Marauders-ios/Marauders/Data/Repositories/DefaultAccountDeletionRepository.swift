//
//  DefaultAccountDeletionRepository.swift
//  Marauders
//

import Foundation

struct DefaultAccountDeletionRepository: AccountDeletionRepository {
    private let apiClient: AccountDeletionAPIClient

    init(apiClient: AccountDeletionAPIClient) {
        self.apiClient = apiClient
    }

    func deleteAccount(authorizationCode: String?) async throws {
        try await apiClient.deleteAccount(authorizationCode: authorizationCode)
    }
}
