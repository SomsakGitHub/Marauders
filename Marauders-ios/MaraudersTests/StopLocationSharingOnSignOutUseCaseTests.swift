//
//  StopLocationSharingOnSignOutUseCaseTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What a sign out asks of the Worker about location sharing: switch it off, and never be held back by the answer.
@MainActor
struct StopLocationSharingOnSignOutUseCaseTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func switchesSharingOffOnTheWorker() async {
        let repository = SignOutSharingRepository(sharing: true)

        let outcome = await StopLocationSharingOnSignOutUseCase(repository: repository).execute()

        #expect(outcome == .switchedOff)
        #expect(repository.calls.map(\.enabled) == [false])
        #expect(!repository.sharing)
    }

    @Test func aCallThatFailsIsReportedWithItsReasonAndNeverThrown() async {
        let repository = SignOutSharingRepository(sharing: true)
        repository.failure = LocationSharingError.serverError(503)

        let outcome = await StopLocationSharingOnSignOutUseCase(repository: repository).execute()

        #expect(outcome == .failed(reason: "Server responded with status 503"))
        #expect(repository.calls.count == 1)
        #expect(repository.sharing, "the Worker was not changed")
    }

    /// A transport that never answers must not hold the sign out back: the bound is the use case's own, not the
    /// request's.
    @Test(.timeLimit(.minutes(1)))
    func aCallThatNeverAnswersIsGivenUpAtTheTimeout() async {
        let gate = SignOutGate()
        let repository = SignOutSharingRepository(sharing: true)
        repository.gate = gate

        let outcome = await StopLocationSharingOnSignOutUseCase(repository: repository, timeout: .milliseconds(50))
            .execute()

        #expect(outcome == .timedOut)
        #expect(repository.calls.count == 1)
        await gate.open()
    }

    /// A request that is given up must not go on in the background: `URLSession` ends it when its task is cancelled.
    @Test(.timeLimit(.minutes(1)))
    func aSlowCallIsCancelledWhenTheTimeoutIsReached() async {
        let repository = SignOutSharingRepository(sharing: true)
        repository.delay = .seconds(60)

        let outcome = await StopLocationSharingOnSignOutUseCase(repository: repository, timeout: .milliseconds(50))
            .execute()
        await waitUntil { repository.cancelledCalls == 1 }

        #expect(outcome == .timedOut)
        #expect(repository.cancelledCalls == 1)
        #expect(repository.sharing, "a call that was cancelled changed nothing")
    }

    /// The answer that arrives first is the outcome; the timer that is left behind changes nothing later.
    @Test func anAnswerInTimeIsNotOverruledByTheTimer() async {
        let repository = SignOutSharingRepository(sharing: true)
        repository.delay = .milliseconds(10)

        let outcome = await StopLocationSharingOnSignOutUseCase(repository: repository, timeout: .seconds(30))
            .execute()

        #expect(outcome == .switchedOff)
        #expect(repository.cancelledCalls == 0)
    }

    /// "A few seconds": long enough for a request on a poor network, short enough that nobody thinks the app froze.
    @Test func theDefaultBoundIsAFewSeconds() {
        let bound = StopLocationSharingOnSignOutUseCase.defaultTimeout

        #expect(bound >= .seconds(2))
        #expect(bound <= .seconds(5))
    }
}
