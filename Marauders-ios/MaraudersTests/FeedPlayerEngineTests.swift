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
}
