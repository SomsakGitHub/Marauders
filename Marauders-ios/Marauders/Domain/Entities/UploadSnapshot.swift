//
//  UploadSnapshot.swift
//  Marauders
//

import Foundation

/// Where the viewer's clip upload stands, as the uploader tells it.
nonisolated enum UploadSnapshot: Equatable, Sendable {
    /// No upload: nothing is being sent and nothing is left for the viewer to see.
    case idle
    /// The clip is going out. `fraction` runs from 0 up to, and never including, 1: every byte sent is `finishing`.
    case uploading(fraction: Double)
    /// Every byte is sent and the Worker has not answered yet.
    case finishing
    /// The Worker stored the clip.
    case finished(FeedVideo)
    /// The upload ended without a clip. `message` is for the viewer; `canRetry` says whether Try again can work.
    case failed(message: String, canRetry: Bool)
}
