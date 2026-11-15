//
//  VideoUploadRepository.swift
//  Marauders
//

import Foundation

/// Called with how much of an upload's body has been sent, from 0 to 1. It runs on whatever thread the transfer uses,
/// so a handler that touches the state of an actor hops to that actor first.
typealias UploadProgressHandler = @Sendable (_ fraction: Double) -> Void

protocol VideoUploadRepository: Sendable {
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?
    ) async throws -> FeedVideo

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String
    ) async throws -> FeedVideo

    /// Like the overload above, and tells `progress` how much of the upload's body has been sent, from 0 to 1.
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?
    ) async throws -> FeedVideo
}

extension VideoUploadRepository {
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?
    ) async throws -> FeedVideo {
        try await upload(fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption)
    }

    /// For a repository that cannot tell how far an upload has got: it uploads and never calls `progress`.
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?, progress: UploadProgressHandler?
    ) async throws -> FeedVideo {
        try await upload(
            fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption,
            audioAssessment: audioAssessment)
    }
}
