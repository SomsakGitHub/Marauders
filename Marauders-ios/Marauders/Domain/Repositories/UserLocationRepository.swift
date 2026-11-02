//
//  UserLocationRepository.swift
//  Marauders
//

import Foundation

protocol UserLocationRepository: Sendable {
    func report(location: ClipLocation) async throws
    /// What the app sends while it is closed. The Worker keeps it only while the viewer shares, and answers whether they
    /// still do; nil from a Worker that does not say.
    func reportWhileClosed(location: ClipLocation) async throws -> Bool?
}
