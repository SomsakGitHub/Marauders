//
//  VideoExporting.swift
//  Marauders
//

import Foundation

protocol VideoExporting: Sendable {
    func mp4URLForUpload(from sourceURL: URL) async throws -> URL
}
