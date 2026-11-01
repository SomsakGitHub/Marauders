//
//  DefaultUserFollowRepository.swift
//  Marauders
//

import Foundation

struct DefaultUserFollowRepository: UserFollowRepository {
    private let apiClient: FollowsAPIClient

    init(apiClient: FollowsAPIClient) {
        self.apiClient = apiClient
    }

    func setFollowing(_ following: Bool, handle: String) async throws -> UserFollowChange {
        try await apiClient.setFollowing(following, handle: handle)
    }
}
