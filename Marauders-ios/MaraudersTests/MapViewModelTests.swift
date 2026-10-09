//
//  MapViewModelTests.swift
//  MaraudersTests
//

import CoreLocation
import Testing
@testable import Marauders

@MainActor
struct MapViewModelTests {
    @Test func notDeterminedShowsPrePrompt() {
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .notDetermined else { return }

        let viewModel = MapViewModel(locationManager: manager)
        viewModel.currentLocationButtonTapped()

        #expect(viewModel.showLocationPrePrompt)
    }

    @Test func confirmDismissesPrePrompt() {
        let viewModel = MapViewModel()
        viewModel.showLocationPrePrompt = true

        viewModel.confirmLocationPermissionRequest()

        #expect(!viewModel.showLocationPrePrompt)
    }

    @Test func cancelDismissesPrePrompt() {
        let viewModel = MapViewModel()
        viewModel.showLocationPrePrompt = true

        viewModel.cancelLocationPermissionRequest()

        #expect(!viewModel.showLocationPrePrompt)
    }
}
