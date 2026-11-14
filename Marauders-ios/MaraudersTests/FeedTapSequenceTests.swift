//
//  FeedTapSequenceTests.swift
//  Marauders
//

import Foundation
import Testing
import UIKit

@testable import Marauders

@MainActor
struct FeedTapSequenceTests {
    @Test func aLoneTapWaitsToSeeWhetherASecondOneComes() {
        var taps = FeedTapSequence()
        #expect(taps.tap(at: 10) == .waitForSecondTap)
    }

    @Test func aQuickSecondTapIsAHeart() {
        var taps = FeedTapSequence()
        _ = taps.tap(at: 10)
        #expect(taps.tap(at: 10.29) == .heart)
    }

    @Test func aSlowSecondTapIsATapOfItsOwn() {
        var taps = FeedTapSequence()
        _ = taps.tap(at: 10)
        #expect(taps.tap(at: 10.31) == .waitForSecondTap)
    }

    /// As on TikTok, the taps after a double tap keep adding hearts while they keep coming, even slower than a double tap.
    @Test func everyQuickTapAfterAHeartAddsOneMore() {
        var taps = FeedTapSequence()
        _ = taps.tap(at: 10)
        _ = taps.tap(at: 10.2)
        #expect(taps.tap(at: 10.75) == .heart)
        // Each heart keeps the run going.
        #expect(taps.tap(at: 11.3) == .heart)
    }

    @Test func theHeartsStopOnceTheTapsDo() {
        var taps = FeedTapSequence()
        _ = taps.tap(at: 10)
        _ = taps.tap(at: 10.2)
        #expect(taps.tap(at: 10.85) == .waitForSecondTap)
    }

    @Test func aTapAfterTheHeartsCanStartANewDoubleTap() {
        var taps = FeedTapSequence()
        _ = taps.tap(at: 10)
        _ = taps.tap(at: 10.2)
        #expect(taps.tap(at: 12) == .waitForSecondTap)
        #expect(taps.tap(at: 12.1) == .heart)
    }

    @Test func tapsFarApartNeverMakeAHeart() {
        var taps = FeedTapSequence()
        for time in stride(from: 10.0, to: 13.0, by: 0.5) {
            #expect(taps.tap(at: time) == .waitForSecondTap)
        }
    }
}

/// How the feed's paging view hands taps on: the pause waits out a double tap, and a double tap does not pause.
@MainActor
struct FeedPagingViewTapTests {
    private final class Recorder {
        var pauses = 0
        var hearts: [CGPoint] = []
    }

    private func makeView(withDoubleTap: Bool = true) -> (VerticalFeedPagingView, Recorder) {
        let view = VerticalFeedPagingView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let recorder = Recorder()
        view.onTap = { recorder.pauses += 1 }
        if withDoubleTap { view.onDoubleTap = { recorder.hearts.append($0) } }
        return (view, recorder)
    }

    /// Well past the moment a tap stops waiting for a second one. The main actor the waiting tap runs on is shared with
    /// the other tests running at the same time, so a pause can come late.
    private func waitOutTheDoubleTap() async {
        try? await Task.sleep(for: .seconds(FeedTapSequence.doubleTapInterval + 1))
    }

    /// Waits, for up to three seconds, for a pause that waited out a double tap.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aSingleTapPausesOnlyOnceNoSecondTapCame() async {
        let (view, recorder) = makeView()

        view.handleTap(at: CGPoint(x: 10, y: 20), time: 100)
        #expect(recorder.pauses == 0)

        await waitUntil { recorder.pauses > 0 }
        #expect(recorder.pauses == 1)
        #expect(recorder.hearts.isEmpty)
    }

    @Test func aDoubleTapLikesWhereTheSecondTapWasAndDoesNotPause() async {
        let (view, recorder) = makeView()

        view.handleTap(at: CGPoint(x: 10, y: 20), time: 100)
        view.handleTap(at: CGPoint(x: 30, y: 40), time: 100.2)
        #expect(recorder.hearts == [CGPoint(x: 30, y: 40)])

        await waitOutTheDoubleTap()
        #expect(recorder.pauses == 0)
    }

    @Test func withoutADoubleTapHandlerATapPausesAtOnce() {
        let (view, recorder) = makeView(withDoubleTap: false)

        view.handleTap(at: .zero, time: 100)
        view.handleTap(at: .zero, time: 100.1)

        #expect(recorder.pauses == 2)
    }

    @Test func aSwipeDropsATapStillWaitingAndEndsTheHearts() async throws {
        let (view, recorder) = makeView()
        let scroll = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)

        view.handleTap(at: .zero, time: 100)
        view.scrollViewWillBeginDragging(scroll)
        await waitOutTheDoubleTap()
        #expect(recorder.pauses == 0)

        // A quick tap after the swipe is a first tap again, not a heart.
        view.handleTap(at: .zero, time: 100.1)
        #expect(recorder.hearts.isEmpty)
    }
}
