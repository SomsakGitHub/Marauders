//
//  UserProfileRepository.swift
//  Marauders
//

import Foundation

protocol UserProfileRepository: Sendable {
    func fetchProfile() async throws -> UserProfile
    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile
    func updateHandle(_ handle: String) async throws -> String
    func deleteClip(id: UUID) async throws
}
