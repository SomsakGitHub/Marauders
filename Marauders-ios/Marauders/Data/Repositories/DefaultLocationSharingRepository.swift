//
//  DefaultLocationSharingRepository.swift
//  Marauders
//

import Foundation

struct DefaultLocationSharingRepository: LocationSharingRepository {
    private let apiClient: LocationSharingAPIClient

    init(apiClient: LocationSharingAPIClient) {
        self.apiClient = apiClient
    }

    func friendLocations() async throws -> FriendLocations {
        try await apiClient.friendLocations()
    }

    func setSharing(_ enabled: Bool) async throws -> Bool {
        try await apiClient.setSharing(enabled)
    }
}
