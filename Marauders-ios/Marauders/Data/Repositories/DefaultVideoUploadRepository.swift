//
//  DefaultVideoUploadRepository.swift
//  Marauders
//

import Foundation

struct DefaultVideoUploadRepository: VideoUploadRepository {
    private let apiClient: VideoUploadAPIClient

    init(apiClient: VideoUploadAPIClient) {
        self.apiClient = apiClient
    }

    func upload(fileURL: URL, mimeType: String) async throws -> FeedVideo {
        try await apiClient.upload(fileURL: fileURL, mimeType: mimeType)
    }
}
