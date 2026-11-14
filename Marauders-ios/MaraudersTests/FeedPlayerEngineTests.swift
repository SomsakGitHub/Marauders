//
//  FeedPlayerEngineTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct FeedPlayerEngineTests {

    @Test func playRejectsNonHTTPSURL() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(string: "http://cdn.example.com/video.mp4")!)

        #expect(engine.phase == .failed("URL is not secure"))
        #expect(engine.showsBufferingIndicator == false)
    }

    @Test func playRejectsFileURL() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(fileURLWithPath: "/tmp/video.mp4"))

        #expect(engine.phase == .failed("URL is not secure"))
    }

    @Test func prefetchIgnoresNonHTTPSURL() {
        let engine = FeedPlayerEngine()
        engine.prefetch(url: URL(string: "http://cdn.example.com/video.mp4")!)

        #expect(engine.phase == .idle)
    }

    @Test func userPauseSetsPausedPhaseAndHidesSpinner() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(string: "https://example.com/video.mp4")!)
        #expect(engine.phase == .buffering)

        engine.pause(byUser: true)

        #expect(engine.phase == .paused)
        #expect(engine.showsBufferingIndicator == false)
    }

    @Test func systemPauseDoesNotMarkUserPaused() {
        let engine = FeedPlayerEngine()
        engine.pause(byUser: true)
        engine.pause(byUser: false)

        #expect(engine.phase == .paused)
    }

    @Test func retryWithoutCurrentURLIsNoOp() {
        let engine = FeedPlayerEngine()
        engine.retry()

        #expect(engine.phase == .idle)
    }

    @Test func aClipTheViewerPausedIsNotResumedAfterASheetCloses() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(string: "https://example.com/video.mp4")!)
        engine.pause(byUser: true)

        #expect(engine.phase == .paused)
        #expect(engine.phase.shouldResumeAfterInterruption == false)
    }

    @Test func aClipStillBufferingIsResumedAfterASheetCloses() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(string: "https://example.com/video.mp4")!)

        #expect(engine.phase == .buffering)
        #expect(engine.phase.shouldResumeAfterInterruption)
    }

    @Test func aClipThatFailedToLoadIsRetriedAfterASheetCloses() {
        let engine = FeedPlayerEngine()
        engine.play(url: URL(string: "http://example.com/video.mp4")!)

        #expect(engine.phase == .failed("URL is not secure"))
        #expect(engine.phase.shouldResumeAfterInterruption)
    }

    @Test func warmURLsSkipsInvalidEntries() {
        let engine = FeedPlayerEngine()
        engine.warmURLs([
            URL(string: "ftp://example.com/a.mp4")!,
            URL(string: "https://example.com/ok.mp4")!,
        ])

        #expect(engine.phase == .idle)
    }

    @Test func playSameHTTPSURLTwiceDoesNotFail() {
        let engine = FeedPlayerEngine()
        let url = URL(string: "https://example.com/video.mp4")!

        engine.play(url: url)
        let phaseAfterFirst = engine.phase

        engine.play(url: url)

        #expect(phaseAfterFirst == .buffering)
        #expect(engine.phase != .failed("URL is not secure"))
    }

    @Test func theEngineLooksForAClipInTheMediaCacheItWasGiven() async {
        let cache = LookupRecordingMediaCache()
        let engine = FeedPlayerEngine(mediaCache: cache)
        let url = URL(string: "https://example.com/video.mp4")!

        engine.play(url: url)

        // The engine asks from a task it starts, so wait for the lookup instead of sleeping a fixed time.
        var waited = 0
        while cache.lookups.isEmpty, waited < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(cache.lookups == [url])
    }

    @Test func preloadKeepsFirstNeighborEvenWhenAlreadyWarm() {
        let current = URL(string: "https://example.com/current.mp4")!
        let next = URL(string: "https://example.com/next.mp4")!
        let previous = URL(string: "https://example.com/previous.mp4")!
        #expect(FeedPlayerEngine.preloadTarget(currentURL: current, neighbors: [next, previous]) == next)
        #expect(FeedPlayerEngine.preloadTarget(currentURL: current, neighbors: [current, next]) == next)
    }

    @Test func preloadSkipsInsecureNeighbors() {
        let next = URL(string: "https://example.com/next.mp4")!
        #expect(
            FeedPlayerEngine.preloadTarget(
                currentURL: nil,
                neighbors: [
                    URL(string: "http://example.com/invalid.mp4")!, next,
                ]) == next)
        #expect(FeedPlayerEngine.preloadTarget(currentURL: next, neighbors: [next]) == nil)
    }
}

/// A media cache that holds no files and writes down which clips the engine asked it about. A class, not an actor:
/// Swift 6.4 does not let an actor conform to this MainActor-isolated protocol.
private final class LookupRecordingMediaCache: FeedMediaCaching, @unchecked Sendable {
    private(set) var lookups: [URL] = []

    func localURL(for remote: URL) async -> URL? {
        lookups.append(remote)
        return nil
    }

    func invalidate(_ remote: URL) async {}
}
