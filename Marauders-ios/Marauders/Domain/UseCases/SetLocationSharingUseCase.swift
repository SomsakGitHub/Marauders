//
//  SetLocationSharingUseCase.swift
//  Marauders
//

import Foundation

struct SetLocationSharingUseCase {
    private let repository: LocationSharingRepository

    init(repository: LocationSharingRepository) {
        self.repository = repository
    }

    func execute(enabled: Bool) async throws -> Bool {
        try await repository.setSharing(enabled)
    }
}
