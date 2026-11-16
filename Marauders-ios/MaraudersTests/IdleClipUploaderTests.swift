//
//  IdleClipUploaderTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The uploader a screen gets when there is no real one (UI tests, a view model that was not given one): it never
/// uploads, and says so.
@MainActor
struct IdleClipUploaderTests {
    @Test(.timeLimit(.minutes(1)))
    func theIdleUploaderPublishesIdleAndEndsItsStream() async {
        var received: [UploadSnapshot] = []

        for await snapshot in await IdleClipUploader().snapshots() {
            received.append(snapshot)
        }

        #expect(received == [.idle])
    }

    @Test func theIdleUploaderRefusesToStart() async {
        let request = ClipUploadRequest(
            fileURL: URL(fileURLWithPath: "/clips/sunset.mov"),
            mimeType: "video/quicktime",
            clipLocation: ClipLocation(latitude: 13.7563, longitude: 100.5018)!,
            caption: "",
            audioAssessment: nil
        )

        await #expect(throws: ClipUploadError.unavailable) { try await IdleClipUploader().start(request) }
    }

    /// The rest does nothing: a sign out, a sign in or a Try again that reaches it must neither trap nor change what it
    /// publishes.
    @Test(.timeLimit(.minutes(1)))
    func theIdleUploaderIgnoresRetryDiscardAndReconcile() async {
        let uploader = IdleClipUploader()

        await uploader.retry()
        await uploader.discard()
        await uploader.reconcile()

        var received: [UploadSnapshot] = []
        for await snapshot in await uploader.snapshots() {
            received.append(snapshot)
        }
        #expect(received == [.idle])
    }

    @Test func theStartErrorsReadAsTheirTexts() {
        let texts: [(error: ClipUploadError, text: String)] = [
            (.unavailable, "Uploading is not available"),
            (.alreadyUploading, "An upload is already in progress"),
            (.notEnoughSpace, "Not enough free space on this iPhone to upload the clip"),
        ]

        for (error, text) in texts {
            #expect(error.errorDescription == text)
            #expect(error.localizedDescription == text, "what the Upload tab shows for \(error)")
        }
    }
}
