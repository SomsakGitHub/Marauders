//
//  DefaultUserProfileRepository.swift
//  Marauders
//

import Foundation

struct DefaultUserProfileRepository: UserProfileRepository {
    private let apiClient: UserProfileAPIClient

    init(apiClient: UserProfileAPIClient) {
        self.apiClient = apiClient
    }

    func fetchProfile() async throws -> UserProfile {
        try await apiClient.fetchProfile()
    }

    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        try await apiClient.fetchPublicProfile(handle: handle)
    }

    func updateHandle(_ handle: String) async throws -> String {
        try await apiClient.updateHandle(handle)
    }

    func updateAvatar(imageData: Data, mimeType: String) async throws -> URL {
        let ext = mimeType == "image/png" ? "png" : "jpg"
        return try await apiClient.uploadAvatar(
            imageData: imageData,
            mimeType: mimeType,
            filename: "avatar.\(ext)"
        )
    }

    func deleteClip(id: UUID) async throws {
        try await apiClient.deleteClip(id: id)
    }
}
