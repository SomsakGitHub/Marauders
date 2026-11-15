//
//  BackgroundExecutionTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders

@MainActor
struct BackgroundExecutionTests {
    @Test func releasingTwiceIsHarmless() {
        // The unit tests run inside the app, so UIApplication.shared exists and the task is a real one.
        let release = BackgroundExecution.begin("test")

        release()
        release()
    }
}
