//
//  VideoUploadRepository.swift
//  Marauders
//

import Foundation

protocol VideoUploadRepository: Sendable {
    func upload(fileURL: URL, mimeType: String) async throws -> FeedVideo
}
