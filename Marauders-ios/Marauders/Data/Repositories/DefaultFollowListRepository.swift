//
//  DefaultFollowListRepository.swift
//  Marauders
//

import Foundation

struct DefaultFollowListRepository: FollowListRepository {
    private let apiClient: FollowListAPIClient

    init(apiClient: FollowListAPIClient) {
        self.apiClient = apiClient
    }

    func fetchList(handle: String, kind: FollowListKind, cursor: String?, limit: Int) async throws -> FollowListPage {
        try await apiClient.fetchList(handle: handle, kind: kind, cursor: cursor, limit: limit)
    }
}
