//
//  VideoUploadRepository.swift
//  Marauders
//

import Foundation

protocol VideoUploadRepository: Sendable {
    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String,
        musicTitle: String
    ) async throws -> FeedVideo
}
