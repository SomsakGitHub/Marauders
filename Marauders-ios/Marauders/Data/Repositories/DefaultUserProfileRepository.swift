//
//  DefaultUserProfileRepository.swift
//  Marauders
//

import Foundation

struct DefaultUserProfileRepository: UserProfileRepository {
    private let apiClient: UserProfileAPIClient

    init(apiClient: UserProfileAPIClient) {
        self.apiClient = apiClient
    }

    func fetchProfile() async throws -> UserProfile {
        try await apiClient.fetchProfile()
    }
}
