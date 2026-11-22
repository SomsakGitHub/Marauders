//
//  MaraudersTests.swift
//  MaraudersTests
//
//  Created by tiscomacnb2486 on 7/10/2569 BE.
//

import Testing

@testable import Marauders

@MainActor
struct MaraudersTests {
    @Test func feedPlayerPhaseEquatable() {
        // Each side of `==` is a value of its own: a checker reads one expression compared with itself as a mistake.
        let playing = FeedPlayerPhase.playing
        let playingAgain = FeedPlayerPhase.playing
        let failedA = FeedPlayerPhase.failed("a")
        let failedAAgain = FeedPlayerPhase.failed("a")
        #expect(playing == playingAgain)
        #expect(failedA == failedAAgain)
        #expect(failedA != FeedPlayerPhase.failed("b"))
    }
}
