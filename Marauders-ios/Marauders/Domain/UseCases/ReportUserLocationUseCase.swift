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

    /// Answers whether the viewer still shares their location, nil when the Worker does not say.
    func executeWhileClosed(location: ClipLocation) async throws -> Bool? {
        try await repository.reportWhileClosed(location: location)
    }
}
