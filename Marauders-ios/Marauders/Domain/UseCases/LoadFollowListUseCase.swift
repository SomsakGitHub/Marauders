//
//  LoadFollowListUseCase.swift
//  Marauders
//

import Foundation

struct LoadFollowListUseCase {
    private let repository: FollowListRepository

    init(repository: FollowListRepository) {
        self.repository = repository
    }

    func execute(
        handle: String,
        kind: FollowListKind,
        cursor: String? = nil,
        limit: Int = FollowListRules.pageSize
    ) async throws -> FollowListPage {
        try await repository.fetchList(handle: handle, kind: kind, cursor: cursor, limit: limit)
    }
}
