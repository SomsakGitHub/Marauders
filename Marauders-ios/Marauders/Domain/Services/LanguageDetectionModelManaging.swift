//
//  LanguageDetectionModelManaging.swift
//  Marauders
//

import Foundation

/// The on-device model that listens to a clip and names its language. It is downloaded once, with the
/// viewer's consent, and then works without a network connection.
nonisolated protocol LanguageDetectionModelManaging: Sendable {
    /// Whether the model is on this iPhone and complete.
    func isInstalled() async -> Bool
    /// `.installed`, `.notInstalled` or `.downloading` with the fraction done.
    func status() async -> LanguageModelStatus
    /// Downloads and prepares the model. A download already running is joined, not repeated.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    func remove() async
}

nonisolated enum LanguageDetectionModel {
    /// What the viewer is asked to download, rounded up: the model and its tokenizer.
    static let approximateMegabytes = 150
}
