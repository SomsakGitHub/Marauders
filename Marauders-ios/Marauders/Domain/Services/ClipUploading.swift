//
//  ClipUploading.swift
//  Marauders
//

import Foundation

/// Sends the viewer's clip to the Worker in a way that outlives the screen that asked for it, and says where the upload
/// stands. There is one upload at a time.
nonisolated protocol ClipUploading: Sendable {
    /// Takes the clip over and returns once it is on its way, long before the Worker has answered. Throws a
    /// `ClipUploadError` when the upload cannot be taken on.
    func start(_ request: ClipUploadRequest) async throws

    /// The current snapshot first, then every change after it, so a viewer who looks late still sees where things
    /// stand.
    func snapshots() async -> AsyncStream<UploadSnapshot>

    /// Sends the clip again after a failure that allows it.
    func retry() async

    /// Drops the upload, whatever it is doing: the viewer's choice, a sign out, or the acknowledgement of a clip that
    /// was seen to finish.
    func discard() async

    /// Checks the stored upload against the world as it is now (after a launch or a sign in) and brings its snapshot
    /// in line with it.
    func reconcile() async
}

/// Why an upload could not be taken on, so the viewer is told the real reason.
nonisolated enum ClipUploadError: LocalizedError, Equatable, Sendable {
    /// Nothing can take the clip: there is no uploader, or the upload was discarded while it was starting.
    case unavailable
    /// The earlier clip is still on its way.
    case alreadyUploading
    /// This iPhone has too little free space to keep a copy of the clip while it uploads.
    case notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Uploading is not available")
        case .alreadyUploading: String(localized: "An upload is already in progress")
        case .notEnoughSpace: String(localized: "Not enough free space on this iPhone to upload the clip")
        }
    }
}

/// The uploader a screen has when no real one is wired in (UI tests, a view model that was given none): it never
/// uploads anything, and says so.
nonisolated struct IdleClipUploader: ClipUploading {
    func start(_ request: ClipUploadRequest) async throws {
        throw ClipUploadError.unavailable
    }

    /// `.idle`, and then the stream ends.
    func snapshots() async -> AsyncStream<UploadSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func retry() async {}
    func discard() async {}
    func reconcile() async {}
}
