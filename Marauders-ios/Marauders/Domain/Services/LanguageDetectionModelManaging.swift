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

/// Why the language detection model could not be installed, so the viewer is told the real reason.
enum LanguageDetectionModelError: LocalizedError, Equatable {
    case incompleteDownload
    case unusable

    var errorDescription: String? {
        switch self {
        case .incompleteDownload: String(localized: "The download didn't finish. Try again.")
        case .unusable: String(localized: "The downloaded model couldn't be used on this iPhone. Try again.")
        }
    }
}

nonisolated enum LanguageDetectionModel {
    /// What the viewer is asked to download, rounded up: the model and its tokenizer.
    static let approximateMegabytes = 150
    /// The share of the install's progress taken by downloading the model; the rest is the iPhone checking and
    /// preparing it. `install(progress:)` reports a fraction of the whole, so the player and Settings compare it with
    /// this to tell "Downloading…" from "Preparing…", and to show the download as 0–100 %.
    static let downloadShare = 0.9
}
