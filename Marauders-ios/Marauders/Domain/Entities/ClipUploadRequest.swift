//
//  ClipUploadRequest.swift
//  Marauders
//

import Foundation

/// A clip the viewer chose to upload, with what goes along with it.
nonisolated struct ClipUploadRequest: Sendable {
    /// The exported clip on this iPhone.
    let fileURL: URL
    let mimeType: String
    let clipLocation: ClipLocation
    let caption: String
    let audioAssessment: ClipAudioAssessment?
}
