//
//  UserProfileRepository.swift
//  Marauders
//

import Foundation

protocol UserProfileRepository: Sendable {
    func fetchProfile() async throws -> UserProfile
}
