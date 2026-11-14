//
//  BackgroundLocationMonitorTests.swift
//  Marauders
//

import CoreLocation
import Foundation
import Testing
import UIKit

@testable import Marauders

/// A class, so each test's own defaults are removed after it.
@MainActor
final class BackgroundLocationMonitorTests {
    final class AwakeHolds {
        var begun = 0
        var released = 0
    }

    final class ProtectedData {
        var isAvailable = true
    }

    private let suiteName = "BackgroundLocationMonitorTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let clock = ForegroundLocationReporterTests.Clock()
    private let protectedData = ProtectedData()
    private let notificationCenter = NotificationCenter()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        // `defaults` is not Sendable, and any instance can remove a domain.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeSUT(
        authorization: CLAuthorizationStatus = .authorizedAlways,
        result: Result<Void, Error> = .success(())
    ) -> (BackgroundLocationMonitor, FakeLocationManager, RecordingUserLocationRepository, AwakeHolds) {
        let manager = FakeLocationManager(authorizationStatus: authorization)
        let repository = RecordingUserLocationRepository(result: result)
        let holds = AwakeHolds()
        let clock = clock
        let protectedData = protectedData
        let monitor = BackgroundLocationMonitor(
            locationManager: manager,
            report: ReportUserLocationUseCase(repository: repository),
            defaults: defaults,
            holdAwake: { _ in
                holds.begun += 1
                return { holds.released += 1 }
            },
            now: { clock.now },
            isProtectedDataAvailable: { protectedData.isAvailable },
            notificationCenter: notificationCenter
        )
        return (monitor, manager, repository, holds)
    }

    private func fix(latitude: Double = 13.7563, longitude: Double = 100.5018, age: TimeInterval = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 65,
            verticalAccuracy: -1,
            timestamp: clock.now.addingTimeInterval(-age)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func sharingWithAlwaysAccessStartsBothServices() {
        let (monitor, manager, _, _) = makeSUT()

        monitor.setSharing(true)

        #expect(manager.significantChangeStarts == 1)
        #expect(manager.visitStarts == 1)
        #expect(manager.delegate != nil)
        #expect(monitor.isAlwaysAuthorized)
    }

    @Test func nothingStartsUntilTheViewerShares() {
        let (monitor, manager, _, _) = makeSUT()

        monitor.resume()

        #expect(manager.significantChangeStarts == 0)
        #expect(manager.visitStarts == 0)
    }

    /// A launch with sharing off stops whatever a run before may have left on, so iOS stops waking the app.
    @Test func aLaunchWithoutSharingStopsServicesLeftOn() {
        let (monitor, manager, _, _) = makeSUT()

        monitor.resume()

        #expect(manager.significantChangeStops == 1)
        #expect(manager.visitStops == 1)
    }

    @Test func accessWhileInUseOnlyStartsNothing() {
        let (monitor, manager, _, _) = makeSUT(authorization: .authorizedWhenInUse)

        monitor.setSharing(true)

        #expect(manager.significantChangeStarts == 0)
        #expect(!monitor.isAlwaysAuthorized)
    }

    @Test func alwaysTurnedOnInSettingsStartsTheServicesAndLessStopsThem() {
        let (monitor, manager, _, _) = makeSUT(authorization: .authorizedWhenInUse)
        monitor.setSharing(true)

        manager.authorizationStatus = .authorizedAlways
        manager.simulateAuthorizationChange()
        #expect(manager.significantChangeStarts == 1)
        #expect(monitor.isAlwaysAuthorized)

        manager.authorizationStatus = .authorizedWhenInUse
        manager.simulateAuthorizationChange()
        #expect(manager.significantChangeStops == 1)
        #expect(manager.visitStops == 1)
        #expect(!monitor.isAlwaysAuthorized)
    }

    @Test func turningSharingOffStopsBothServices() {
        let (monitor, manager, _, _) = makeSUT()
        monitor.setSharing(true)

        monitor.setSharing(false)

        #expect(manager.significantChangeStops == 1)
        #expect(manager.visitStops == 1)
    }

    /// The Worker saying so again, on every refresh, starts nothing twice.
    @Test func sharingSaidAgainChangesNothing() {
        let (monitor, manager, _, _) = makeSUT()

        monitor.setSharing(true)
        monitor.setSharing(true)

        #expect(manager.significantChangeStarts == 1)
    }

    /// iOS launches the app in the background for a move, before anything can ask the Worker.
    @Test func aLaunchRemembersThatTheViewerShares() {
        let (first, _, _, _) = makeSUT()
        first.setSharing(true)

        let (relaunched, manager, _, _) = makeSUT()
        relaunched.resume()

        #expect(manager.significantChangeStarts == 1)
        #expect(manager.visitStarts == 1)
        #expect(manager.significantChangeStops == 0)
    }

    /// Before the first unlock after a restart the saved choice cannot be read and looks unset. Stopping then would end
    /// the sharing for good, so the services are left alone until the unlock.
    @Test func aLaunchBeforeTheFirstUnlockWaitsForIt() async {
        let (first, _, _, _) = makeSUT()
        first.setSharing(true)
        defaults.removeObject(forKey: BackgroundLocationMonitor.sharingKey)
        protectedData.isAvailable = false

        let (relaunched, manager, _, _) = makeSUT()
        relaunched.resume()
        #expect(manager.significantChangeStops == 0)
        #expect(manager.significantChangeStarts == 0)

        // The unlock makes the saved choice readable again.
        defaults.set(true, forKey: BackgroundLocationMonitor.sharingKey)
        protectedData.isAvailable = true
        notificationCenter.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await waitUntil { manager.significantChangeStarts == 1 }

        #expect(manager.significantChangeStarts == 1)
        #expect(manager.visitStarts == 1)
        #expect(manager.significantChangeStops == 0)
    }

    /// Locked again after the first unlock, the iPhone still reads the saved choice: that is when most moves come.
    @Test func aLaunchWhileLockedAfterTheFirstUnlockStartsAtOnce() {
        let (first, _, _, _) = makeSUT()
        first.setSharing(true)
        protectedData.isAvailable = false

        let (relaunched, manager, _, _) = makeSUT()
        relaunched.resume()

        #expect(manager.significantChangeStarts == 1)
        #expect(manager.visitStarts == 1)
    }

    /// Someone who never shared has nothing saved; once the iPhone is unlocked that means off.
    @Test func nothingSavedAfterTheUnlockMeansOff() {
        let (monitor, manager, _, _) = makeSUT()

        monitor.resume()

        #expect(manager.significantChangeStops == 1)
        #expect(manager.significantChangeStarts == 0)
    }

    @Test func aMoveSendsTheLatestFixAndKeepsTheAppAwakeUntilItIsThrough() async {
        let (monitor, manager, repository, holds) = makeSUT()
        monitor.setSharing(true)

        manager.simulateLocations([fix(latitude: 13.70, age: 60), fix(latitude: 13.75)])
        await waitUntil { holds.released == 1 }

        #expect(repository.whileClosedCount == 1, "sent as a report from a closed app")
        #expect(repository.lastReported?.latitude == 13.75)
        #expect(holds.begun == 1)
        #expect(holds.released == 1)
    }

    /// Sharing turned off on another device: the Worker kept nothing, and says so.
    @Test func aReportAnsweredNotSharingStopsIt() async {
        let (monitor, manager, repository, _) = makeSUT()
        repository.sharesLocation = false
        monitor.setSharing(true)

        manager.simulateLocations([fix()])
        await waitUntil { manager.significantChangeStops == 1 }

        #expect(manager.visitStops == 1)
        #expect(defaults.bool(forKey: BackgroundLocationMonitor.sharingKey) == false)
    }

    @Test func aWorkerThatDoesNotSayKeepsItGoing() async {
        let (monitor, manager, repository, holds) = makeSUT()
        repository.sharesLocation = nil
        monitor.setSharing(true)

        manager.simulateLocations([fix()])
        await waitUntil { holds.released == 1 }

        #expect(manager.significantChangeStops == 0)
        #expect(defaults.bool(forKey: BackgroundLocationMonitor.sharingKey))
    }

    @Test func aFixFromLongAgoIsNotSent() async {
        let (monitor, manager, repository, holds) = makeSUT()
        monitor.setSharing(true)

        manager.simulateLocations([fix(age: BackgroundLocationMonitor.maximumFixAge + 1)])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(repository.reportCount == 0)
        #expect(holds.begun == 0)
    }

    @Test func aFixWithoutAPositionIsNotSent() async {
        let (monitor, manager, repository, _) = makeSUT()
        monitor.setSharing(true)

        manager.simulateLocations([
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 13.75, longitude: 100.50),
                altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: clock.now
            )
        ])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(repository.reportCount == 0)
    }

    @Test func aFixAfterSharingStoppedIsNotSent() async {
        let (monitor, manager, repository, _) = makeSUT()
        monitor.setSharing(true)
        monitor.setSharing(false)

        manager.simulateLocations([fix()])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(repository.reportCount == 0)
    }

    @Test func anArrivalSendsWhereTheViewerIsAndADepartureDoesNot() async {
        let (monitor, manager, repository, _) = makeSUT()
        monitor.setSharing(true)

        manager.simulateVisit(FakeVisit(latitude: 13.80, longitude: 100.60, departureDate: clock.now))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(repository.reportCount == 0, "a departure is where the viewer was")

        manager.simulateVisit(FakeVisit(latitude: 13.80, longitude: 100.60, departureDate: .distantFuture))
        await waitUntil { repository.reportCount == 1 }
        #expect(repository.lastReported?.latitude == 13.80)
        #expect(repository.lastReported?.longitude == 100.60)
    }

    /// Signed out, or the session went bad: the next launch's own requests end it, so the services stop meanwhile.
    @Test(arguments: [UserLocationAPIError.notAuthenticated, .serverError(401)])
    func aReportWithoutAGoodSessionStopsIt(error: UserLocationAPIError) async {
        let (monitor, manager, repository, _) = makeSUT(result: .failure(error))
        monitor.setSharing(true)

        manager.simulateLocations([fix()])
        await waitUntil { manager.significantChangeStops == 1 }

        #expect(repository.reportCount == 1)
        #expect(manager.visitStops == 1)
        #expect(defaults.bool(forKey: BackgroundLocationMonitor.sharingKey) == false)
    }

    @Test func anyOtherFailureKeepsItGoing() async {
        let (monitor, manager, repository, holds) = makeSUT(result: .failure(UserLocationAPIError.serverError(500)))
        monitor.setSharing(true)

        manager.simulateLocations([fix()])
        await waitUntil { holds.released == 1 }

        #expect(repository.reportCount == 1)
        #expect(manager.significantChangeStops == 0)
        #expect(defaults.bool(forKey: BackgroundLocationMonitor.sharingKey))
    }

    /// Sharing turned off and on again while a report was out: its 401 belongs to before and stops nothing.
    @Test func aRejectedReportFromBeforeAChangeStopsNothing() async {
        let (monitor, manager, repository, holds) = makeSUT(result: .failure(UserLocationAPIError.serverError(401)))
        monitor.setSharing(true)
        manager.simulateLocations([fix()])
        // Before the report has run: it goes out from a task.
        monitor.setSharing(false)
        monitor.setSharing(true)
        await waitUntil { holds.released == 1 }

        #expect(repository.reportCount == 1)
        #expect(manager.significantChangeStarts == 2)
        #expect(manager.significantChangeStops == 1)
        #expect(defaults.bool(forKey: BackgroundLocationMonitor.sharingKey))
    }
}

/// `CLVisit` has no initializer that sets its values.
nonisolated final class FakeVisit: CLVisit, @unchecked Sendable {
    private let fakeCoordinate: CLLocationCoordinate2D
    private let fakeDepartureDate: Date

    init(latitude: Double, longitude: Double, departureDate: Date) {
        fakeCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        fakeDepartureDate = departureDate
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var coordinate: CLLocationCoordinate2D { fakeCoordinate }
    override var departureDate: Date { fakeDepartureDate }
    override var arrivalDate: Date { .distantPast }
    override var horizontalAccuracy: CLLocationAccuracy { 50 }
}
