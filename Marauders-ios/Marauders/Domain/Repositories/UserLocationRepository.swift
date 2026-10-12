//
//  UserLocationRepository.swift
//  Marauders
//

import Foundation

protocol UserLocationRepository: Sendable {
    func report(location: ClipLocation) async throws
}
