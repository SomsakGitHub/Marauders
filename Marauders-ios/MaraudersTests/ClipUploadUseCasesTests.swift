//
//  ClipUploadUseCasesTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What the use cases above the uploader do: hand each call to it, and give back what it publishes or throws.
@MainActor
struct ClipUploadUseCasesTests {
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!

    @Test func startForwardsTheRequestAndRethrowsTheUploadersError() async throws {
        let uploader = FakeClipUploader()
        let useCases = ClipUploadUseCases(uploader: uploader)
        let file = URL(fileURLWithPath: "/clips/sunset.mov")
        let assessment = ClipAudioAssessment(signal: .detected)
        let request = ClipUploadRequest(
            fileURL: file,
            mimeType: "video/quicktime",
            clipLocation: Self.bangkok,
            caption: "Sunset over Bangkok",
            audioAssessment: assessment
        )

        try await useCases.start.execute(request)

        let forwarded = try #require(uploader.started.first)
        #expect(uploader.started.count == 1)
        #expect(forwarded.fileURL == file)
        #expect(forwarded.mimeType == "video/quicktime")
        #expect(forwarded.clipLocation == Self.bangkok)
        #expect(forwarded.caption == "Sunset over Bangkok")
        #expect(forwarded.audioAssessment == assessment)

        uploader.startError = ClipUploadError.notEnoughSpace
        await #expect(throws: ClipUploadError.notEnoughSpace) { try await useCases.start.execute(request) }
        #expect(uploader.started.count == 2, "a refused request still reached the uploader")
    }

    @Test(.timeLimit(.minutes(1)))
    func observeYieldsWhatTheUploaderPublishesInOrder() async {
        let uploader = FakeClipUploader()
        let useCases = ClipUploadUseCases(uploader: uploader)
        let video = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        var snapshots = await useCases.observe.execute().makeAsyncIterator()

        let first = await snapshots.next()
        uploader.emit(.uploading(fraction: 0.5))
        uploader.emit(.finished(video))
        let second = await snapshots.next()
        let third = await snapshots.next()

        #expect(first == .idle, "the current snapshot comes first")
        #expect(second == .uploading(fraction: 0.5))
        #expect(third == .finished(video))

        var late = await useCases.observe.execute().makeAsyncIterator()
        let current = await late.next()
        #expect(current == .finished(video), "a viewer who starts watching late is told where things stand")
    }

    /// Each call is checked on its own, so a use case that reaches for the wrong method cannot hide behind another.
    @Test func retryDiscardAndReconcileEachReachTheUploaderOnce() async {
        let uploader = FakeClipUploader()
        let useCases = ClipUploadUseCases(uploader: uploader)

        await useCases.retry.execute()
        #expect(Self.counts(of: uploader) == [1, 0, 0])

        await useCases.discard.execute()
        #expect(Self.counts(of: uploader) == [1, 1, 0])

        await useCases.reconcile.execute()
        #expect(Self.counts(of: uploader) == [1, 1, 1])
    }

    /// How often the uploader was asked to retry, discard and reconcile, in that order.
    private static func counts(of uploader: FakeClipUploader) -> [Int] {
        [uploader.retries, uploader.discards, uploader.reconciles]
    }
}
