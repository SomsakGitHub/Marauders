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
}

extension VideoUploadRepository {
    func upload(
        fileURL: URL, mimeType: String, clipLocation: ClipLocation, caption: String,
        audioAssessment: ClipAudioAssessment?
    ) async throws -> FeedVideo {
        try await upload(fileURL: fileURL, mimeType: mimeType, clipLocation: clipLocation, caption: caption)
    }
}
