//
//  UpdateUserHandleUseCase.swift
//  Marauders
//

import Foundation

struct UpdateUserHandleUseCase {
    private let repository: UserProfileRepository

    init(repository: UserProfileRepository) {
        self.repository = repository
    }

    /// Returns the normalized handle saved by the server.
    func execute(_ handle: String) async throws -> String {
        try await repository.updateHandle(handle)
    }
}
