//
//  MaraudersTests.swift
//  MaraudersTests
//
//  Created by tiscomacnb2486 on 7/10/2569 BE.
//

import Testing
@testable import Marauders

struct MaraudersTests {
    @Test func feedPlayerPhaseEquatable() {
        #expect(FeedPlayerPhase.playing == FeedPlayerPhase.playing)
        #expect(FeedPlayerPhase.failed("a") == FeedPlayerPhase.failed("a"))
        #expect(FeedPlayerPhase.failed("a") != FeedPlayerPhase.failed("b"))
    }
}
