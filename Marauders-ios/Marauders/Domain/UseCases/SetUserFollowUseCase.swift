//
//  SetUserFollowUseCase.swift
//  Marauders
//

import Foundation

struct SetUserFollowUseCase {
    private let repository: UserFollowRepository

    init(repository: UserFollowRepository) {
        self.repository = repository
    }

    func execute(handle: String, following: Bool) async throws -> UserFollowChange {
        try await repository.setFollowing(following, handle: handle)
    }
}
