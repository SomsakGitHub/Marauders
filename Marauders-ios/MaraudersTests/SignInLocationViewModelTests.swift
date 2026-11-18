import CoreLocation
import Foundation
import Testing

@testable import Marauders

@MainActor
struct SignInLocationViewModelTests {
    @Test func requestsPermissionAndBlocksUntilCountryResolved() async throws {
        let manager = FakeLocationManager(authorizationStatus: .notDetermined)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in "TH" })
        model.begin()
        #expect(manager.authorizationRequestCount >= 1)
        #expect(!model.canSignIn)
        manager.authorizationStatus = .authorizedWhenInUse
        manager.simulateAuthorizationChange()
        #expect(manager.alwaysAuthorizationRequestCount == 1)
        #expect(!model.canSignIn)
        #expect(manager.locationRequestCount == 0)
        manager.authorizationStatus = .authorizedAlways
        manager.simulateAuthorizationChange()
        #expect(manager.locationRequestCount == 1)
        #expect(!model.canSignIn)
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.canSignIn)
        #expect(model.countryCode == "TH")
        manager.authorizationStatus = .denied
        manager.simulateAuthorizationChange()
        #expect(!model.canSignIn)
        #expect(model.countryCode == nil)
        #expect(model.needsSettings)
        model.stop()
    }
    @Test func downgradeToWhenInUseCancelsCountryLookup() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(
            manager: manager, useUITestState: false,
            resolveCountry: { _ in
                try? await Task.sleep(for: .milliseconds(40))
                return "TH"
            })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        await Task.yield()
        manager.authorizationStatus = .authorizedWhenInUse
        manager.simulateAuthorizationChange()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.canSignIn)
        #expect(!model.isResolving)
        #expect(model.countryCode == nil)
        #expect(model.needsSettings)
        #expect(manager.alwaysAuthorizationRequestCount == 1)
        model.stop()
    }
    @Test func deniedNeverRequestsLocationOrPermitsSignIn() {
        let manager = FakeLocationManager(authorizationStatus: .denied)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false)
        model.begin()
        #expect(!model.canSignIn)
        #expect(model.needsSettings)
        #expect(manager.locationRequestCount == 0)
    }
    @Test func missingCountryDoesNotFallBackToDeviceRegion() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in nil })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.canSignIn)
        #expect(model.countryCode == nil)
        #expect(model.message != nil)
        model.stop()
    }
    @Test func lateCountryCannotOverrideRevokedPermission() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(
            manager: manager, useUITestState: false,
            resolveCountry: { _ in
                try? await Task.sleep(for: .milliseconds(40))
                return "TH"
            })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        await Task.yield()
        manager.authorizationStatus = .denied
        manager.simulateAuthorizationChange()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.canSignIn)
        #expect(model.countryCode == nil)
        model.stop()
    }

    // The texts the gate shows, one test per way of getting there.

    @Test func anUndecidedPermissionAsksForAlways() {
        let manager = FakeLocationManager(authorizationStatus: .notDetermined)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false)
        model.begin()
        #expect(model.message == "Allow location access, then select Always before signing in.")
        model.stop()
    }
    @Test func aPermissionShortOfAlwaysPointsToSettings() {
        for status in [CLAuthorizationStatus.denied, .restricted, .authorizedWhenInUse] {
            let manager = FakeLocationManager(authorizationStatus: status)
            let model = SignInLocationViewModel(manager: manager, useUITestState: false)
            model.begin()
            #expect(
                model.message == "Set location access to Always in Settings before signing in.",
                "status \(status.rawValue)")
            model.stop()
        }
    }
    @Test func aGrantedPermissionSaysTheCountryIsBeingFound() {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in "TH" })
        model.begin()
        #expect(model.message == "Finding your country…")
        model.stop()
    }
    @Test func aLocationFailureSaysSo() {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in "TH" })
        model.begin()
        manager.simulateFailure(CLError(.locationUnknown))
        #expect(model.message == "Could not get your location. Please try again.")
        #expect(!model.canSignIn)
        model.stop()
    }
    @Test func aLocationThatIsTooOldSaysSo() {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in "TH" })
        model.begin()
        let old = CLLocation(
            coordinate: .init(latitude: 13.75, longitude: 100.5), altitude: 0, horizontalAccuracy: 10,
            verticalAccuracy: 10, timestamp: Date(timeIntervalSinceNow: -600))
        manager.simulateLocations([old])
        #expect(model.message == "Could not get a recent location. Please try again.")
        #expect(!model.canSignIn)
        model.stop()
    }
    @Test func aCountryThatCannotBeReadSaysSo() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in "Nowhere" })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.message == "Could not identify your country. Please try again.")
        model.stop()
    }
    @Test func aLookupThatFailsPointsAtTheConnection() async throws {
        struct Offline: Error {}
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(
            manager: manager, useUITestState: false, resolveCountry: { _ in throw Offline() })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.message == "Could not identify your country. Check your connection and try again.")
        model.stop()
    }
    @Test func aPermissionTakenAwayDuringTheLookupPointsToSettings() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let model = SignInLocationViewModel(
            manager: manager, useUITestState: false,
            resolveCountry: { _ in
                try? await Task.sleep(for: .milliseconds(40))
                return "TH"
            })
        model.begin()
        manager.simulateLocations([CLLocation(latitude: 13.75, longitude: 100.5)])
        await Task.yield()
        // The system has not told the app yet: the model finds out when the country comes back.
        manager.authorizationStatus = .denied
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.message == "Set location access to Always in Settings before signing in.")
        #expect(!model.canSignIn)
        model.stop()
    }
}
