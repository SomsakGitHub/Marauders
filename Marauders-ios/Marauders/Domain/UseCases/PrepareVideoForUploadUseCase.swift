//
//  PrepareVideoForUploadUseCase.swift
//  Marauders
//

import Foundation

struct PrepareVideoForUploadUseCase: Sendable {
    private let exporter: VideoExporting

    init(exporter: VideoExporting) {
        self.exporter = exporter
    }

    func execute(sourceURL: URL) async throws -> URL {
        try await exporter.mp4URLForUpload(from: sourceURL)
    }
}
