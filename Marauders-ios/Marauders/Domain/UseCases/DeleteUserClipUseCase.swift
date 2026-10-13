//
//  DeleteUserClipUseCase.swift
//  Marauders
//

import Foundation

struct DeleteUserClipUseCase {
    private let repository: UserProfileRepository

    init(repository: UserProfileRepository) {
        self.repository = repository
    }

    func execute(id: UUID) async throws {
        try await repository.deleteClip(id: id)
    }
}
