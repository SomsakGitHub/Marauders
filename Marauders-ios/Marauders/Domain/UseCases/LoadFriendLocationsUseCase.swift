//
//  LoadFriendLocationsUseCase.swift
//  Marauders
//

import Foundation

struct LoadFriendLocationsUseCase {
    private let repository: LocationSharingRepository

    init(repository: LocationSharingRepository) {
        self.repository = repository
    }

    func execute() async throws -> FriendLocations {
        try await repository.friendLocations()
    }
}
