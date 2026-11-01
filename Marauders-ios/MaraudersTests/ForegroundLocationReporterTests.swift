//
//  ForegroundLocationReporterTests.swift
//  Marauders
//

import CoreLocation
import Foundation
import Testing

@testable import Marauders

@MainActor
struct ForegroundLocationReporterTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeSUT(
        authorization: CLAuthorizationStatus = .authorizedAlways,
        result: Result<Void, Error> = .success(())
    ) -> (ForegroundLocationReporter, FakeLocationManager, RecordingUserLocationRepository, Clock) {
        let manager = FakeLocationManager(authorizationStatus: authorization)
        let repository = RecordingUserLocationRepository(result: result)
        let clock = Clock()
        let reporter = ForegroundLocationReporter(
            locationManager: manager,
            report: ReportUserLocationUseCase(repository: repository),
            now: { clock.now }
        )
        return (reporter, manager, repository, clock)
    }

    private static let fix = CLLocation(latitude: 13.7563, longitude: 100.5018)

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theFirstChanceAsksForAFixAndSendsIt() async {
        let (reporter, manager, repository, _) = makeSUT()
        manager.desiredAccuracy = kCLLocationAccuracyBest

        reporter.reportIfDue()
        #expect(manager.locationRequestCount == 1)
        #expect(manager.desiredAccuracy == kCLLocationAccuracyHundredMeters, "about 100 m is enough, and costs less")
        manager.simulateLocations([Self.fix])
        await waitUntil { repository.reportCount == 1 }

        #expect(repository.lastReported?.latitude == 13.7563)
        #expect(repository.lastReported?.longitude == 100.5018)
    }

    /// Five minutes count from when the fix was asked for, with a little slack for the timer, so a report goes out on
    /// every tick and not every other one.
    @Test func theNextReportIsDueFiveMinutesAfterTheLastFixWasAskedFor() async {
        let (reporter, manager, repository, clock) = makeSUT()
        reporter.reportIfDue()
        // The fix takes a few seconds to arrive.
        clock.now += 4
        manager.simulateLocations([Self.fix])
        await waitUntil { repository.reportCount == 1 }

        clock.now += ForegroundLocationReporter.interval - ForegroundLocationReporter.timerSlack - 5
        reporter.reportIfDue()
        #expect(manager.locationRequestCount == 1, "too early")

        clock.now += 1
        reporter.reportIfDue()
        #expect(manager.locationRequestCount == 2, "a tick a little before five minutes is on time")
    }

    /// Turning sharing on sends a fresh location whatever went out just before.
    @Test func aForcedReportSkipsTheWait() async {
        let (reporter, manager, repository, _) = makeSUT()
        reporter.reportIfDue()
        manager.simulateLocations([Self.fix])
        await waitUntil { repository.reportCount == 1 }

        reporter.reportIfDue(force: true)

        #expect(manager.locationRequestCount == 2)
    }

    @Test(arguments: [CLAuthorizationStatus.notDetermined, .denied, .restricted])
    func withoutPermissionNothingIsAskedOrSent(status: CLAuthorizationStatus) {
        let (reporter, manager, repository, _) = makeSUT(authorization: status)

        reporter.reportIfDue(force: true)

        #expect(manager.locationRequestCount == 0)
        #expect(manager.authorizationRequestCount == 0, "the reporter never asks for permission")
        #expect(manager.alwaysAuthorizationRequestCount == 0)
        #expect(repository.reportCount == 0)
    }

    @Test func aFixStillBeingAwaitedIsNotAskedForTwice() {
        let (reporter, manager, _, _) = makeSUT()

        reporter.reportIfDue()
        reporter.reportIfDue(force: true)

        #expect(manager.locationRequestCount == 1)
    }

    @Test func aFixThatNeverArrivesIsGivenUpOnAfterAMinute() {
        let (reporter, manager, _, clock) = makeSUT()
        reporter.reportIfDue()

        clock.now += ForegroundLocationReporter.fixTimeout - 1
        reporter.reportIfDue(force: true)
        #expect(manager.locationRequestCount == 1)

        clock.now += 1
        reporter.reportIfDue(force: true)
        #expect(manager.locationRequestCount == 2)
    }

    @Test func aFailedSendIsTriedAgainAtTheNextChance() async {
        let (reporter, manager, repository, _) = makeSUT(result: .failure(StubError.uploadFailed))
        reporter.reportIfDue()
        manager.simulateLocations([Self.fix])
        await waitUntil { repository.reportCount == 1 }
        try? await Task.sleep(for: .milliseconds(20))

        reporter.reportIfDue()

        #expect(manager.locationRequestCount == 2)
    }

    @Test func aFailedFixLetsTheNextChanceAskAgain() {
        let (reporter, manager, _, _) = makeSUT()
        reporter.reportIfDue()

        manager.delegate?.locationManager?(CLLocationManager(), didFailWithError: CLError(.locationUnknown))
        reporter.reportIfDue()

        #expect(manager.locationRequestCount == 2)
    }

    @Test func aResetSendsAgainAtOnce() async {
        let (reporter, manager, repository, _) = makeSUT()
        reporter.reportIfDue()
        manager.simulateLocations([Self.fix])
        await waitUntil { repository.reportCount == 1 }

        reporter.reset()
        reporter.reportIfDue()

        #expect(manager.locationRequestCount == 2)
    }

    /// A fix asked for in the ended session (or before the viewer stopped sharing) must not go out under what came next.
    @Test func aFixAskedForBeforeAResetIsDropped() async {
        let (reporter, manager, repository, _) = makeSUT()
        reporter.reportIfDue()

        reporter.reset()
        manager.simulateLocations([Self.fix])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(repository.reportCount == 0)
    }

    @Test func aFixIsDroppedWhenTheViewerNoLongerShares() async {
        let (reporter, manager, repository, _) = makeSUT()
        reporter.shouldSend = { false }
        reporter.reportIfDue()

        manager.simulateLocations([Self.fix])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(repository.reportCount == 0)
    }

    @Test func itSaysWhenALocationWentOut() async {
        let (reporter, manager, repository, _) = makeSUT()
        var reported = 0
        reporter.onReported = { reported += 1 }

        reporter.reportIfDue()
        manager.simulateLocations([Self.fix])
        await waitUntil { reported == 1 }

        #expect(repository.reportCount == 1)
        #expect(reported == 1)
    }
}
