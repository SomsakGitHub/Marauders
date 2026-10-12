//
//  DefaultUserLocationRepository.swift
//  Marauders
//

import Foundation

struct DefaultUserLocationRepository: UserLocationRepository {
    private let apiClient: UserLocationAPIClient

    init(apiClient: UserLocationAPIClient) {
        self.apiClient = apiClient
    }

    func report(location: ClipLocation) async throws {
        try await apiClient.report(location: location)
    }
}
