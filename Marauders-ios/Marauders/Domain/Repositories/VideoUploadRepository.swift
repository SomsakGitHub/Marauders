//
//  VideoUploadRepository.swift
//  Marauders
//

import Foundation

protocol VideoUploadRepository: Sendable {
    func upload(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String, audioAssessment: ClipAudioAssessment?) async throws -> FeedVideo

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String
    ) async throws -> FeedVideo
}

extension VideoUploadRepository {
    func upload(fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String, audioAssessment: ClipAudioAssessment?) async throws -> FeedVideo {
        try await upload(fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption)
    }
}
