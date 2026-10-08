//
//  DefaultVideoExporter.swift
//  Marauders
//

import Foundation

struct DefaultVideoExporter: VideoExporting {
    func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        try await VideoExportService.mp4URLForUpload(from: sourceURL)
    }
}
