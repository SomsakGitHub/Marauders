//
//  UploadFeedVideoUseCase.swift
//  Marauders
//

import Foundation

struct UploadFeedVideoUseCase: Sendable {
    private let repository: VideoUploadRepository

    init(repository: VideoUploadRepository) {
        self.repository = repository
    }

    func execute(fileURL: URL, mimeType: String = "video/mp4") async throws -> FeedVideo {
        try await repository.upload(fileURL: fileURL, mimeType: mimeType)
    }
}
