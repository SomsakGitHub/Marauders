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
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in
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
        let model = SignInLocationViewModel(manager: manager, useUITestState: false, resolveCountry: { _ in
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
}
