//
//  LoadPublicProfileUseCase.swift
//  Marauders
//

import Foundation

struct LoadPublicProfileUseCase {
    private let repository: UserProfileRepository

    init(repository: UserProfileRepository) {
        self.repository = repository
    }

    func execute(handle: String) async throws -> PublicUserProfile {
        try await repository.fetchPublicProfile(handle: handle)
    }
}
