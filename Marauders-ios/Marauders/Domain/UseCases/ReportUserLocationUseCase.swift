//
//  ReportUserLocationUseCase.swift
//  Marauders
//

import Foundation

struct ReportUserLocationUseCase: Sendable {
    private let repository: UserLocationRepository

    init(repository: UserLocationRepository) {
        self.repository = repository
    }

    func execute(location: ClipLocation) async throws {
        try await repository.report(location: location)
    }
}
