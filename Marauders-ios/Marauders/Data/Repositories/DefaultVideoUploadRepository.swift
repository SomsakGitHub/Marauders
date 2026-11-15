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

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String
    ) async throws -> FeedVideo {
        try await upload(
            fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption,
            audioAssessment: nil, progress: nil)
    }
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?
    ) async throws -> FeedVideo {
        try await upload(
            fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption,
            audioAssessment: audioAssessment, progress: nil)
    }
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?
    ) async throws -> FeedVideo {
        try await apiClient.upload(
            fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption,
            audioAssessment: audioAssessment, progress: progress)
    }
}
