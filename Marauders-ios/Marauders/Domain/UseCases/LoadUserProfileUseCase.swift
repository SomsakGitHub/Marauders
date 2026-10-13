//
//  LoadUserProfileUseCase.swift
//  Marauders
//

import Foundation

struct LoadUserProfileUseCase {
    private let repository: UserProfileRepository

    init(repository: UserProfileRepository) {
        self.repository = repository
    }

    func execute() async throws -> UserProfile {
        try await repository.fetchProfile()
    }
}
