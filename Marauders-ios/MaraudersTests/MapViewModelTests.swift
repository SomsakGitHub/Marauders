//
//  MapViewModelTests.swift
//  MaraudersTests
//

import CoreLocation
import Testing
@testable import Marauders

@MainActor
struct MapViewModelTests {
    @Test func notDeterminedRequestsSystemPermissionDirectly() {
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .notDetermined else { return }

        let viewModel = MapViewModel(locationManager: manager)
        viewModel.beginLocationAccessRequest()

        #expect(!viewModel.showLocationDeniedAlert)
    }

    @Test func deniedCannotAccessMap() {
        let viewModel = MapViewModel()
        viewModel.syncAuthorizationStatusFromSystem()
        guard viewModel.isLocationAccessDeniedOrRestricted else { return }
        #expect(!viewModel.canAccessMap)
    }

    @Test func countryFilterDefaultsToAll() {
        let viewModel = MapViewModel()
        #expect(viewModel.countryFilter == nil)
    }
}
