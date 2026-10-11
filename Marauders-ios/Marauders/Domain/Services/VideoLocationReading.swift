//
//  VideoLocationReading.swift
//  Marauders
//

import Foundation

/// Reads the GPS location embedded in a video file's metadata, if present.
protocol VideoLocationReading: Sendable {
    func location(fromVideoAt url: URL) async -> ClipLocation?
}

/// Null-object default used when no reader is injected.
struct NoopVideoLocationReader: VideoLocationReading {
    func location(fromVideoAt url: URL) async -> ClipLocation? { nil }
}
