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
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = MapViewModel(locationManager: locationManager)

        viewModel.beginLocationAccessRequest()

        #expect(locationManager.authorizationRequestCount == 1)
        #expect(!viewModel.showLocationDeniedAlert)
        #expect(!viewModel.canAccessMap)
    }

    @Test func deniedShowsAlertAndBlocksMap() {
        let locationManager = FakeLocationManager(authorizationStatus: .denied)
        let viewModel = MapViewModel(locationManager: locationManager)

        viewModel.beginLocationAccessRequest()

        #expect(viewModel.showLocationDeniedAlert)
        #expect(!viewModel.canAccessMap)
        #expect(locationManager.authorizationRequestCount == 0)
    }

    @Test func authorizedCanAccessMapAndMapTabRequestsLocation() {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let viewModel = MapViewModel(locationManager: locationManager)

        #expect(viewModel.canAccessMap)

        viewModel.onMapTabBecameActive()

        #expect(locationManager.locationRequestCount == 1)
    }

    @Test func authorizationGrantedAfterRequestStartsLocationUpdate() async {
        let locationManager = FakeLocationManager(authorizationStatus: .notDetermined)
        let viewModel = MapViewModel(locationManager: locationManager)
        viewModel.beginLocationAccessRequest()

        locationManager.authorizationStatus = .authorizedWhenInUse
        locationManager.simulateAuthorizationChange()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(viewModel.canAccessMap)
        #expect(locationManager.locationRequestCount == 1)
    }

    @Test func receivedLocationExposesUserCoordinate() async {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let viewModel = MapViewModel(locationManager: locationManager)
        viewModel.onMapTabBecameActive()

        locationManager.simulateLocations([CLLocation(latitude: 13.7563, longitude: 100.5018)])
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(viewModel.userCoordinate?.latitude == 13.7563)
        #expect(viewModel.cameraCenterGeneration == 1)
    }

    @Test func countryFilterDefaultsToAll() {
        let viewModel = MapViewModel()
        #expect(viewModel.countryFilter == nil)
    }

    @Test func reportsLocationOncePerSession() async {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let repository = RecordingUserLocationRepository()
        let viewModel = MapViewModel(
            locationManager: locationManager,
            reportUserLocation: ReportUserLocationUseCase(repository: repository)
        )
        viewModel.onMapTabBecameActive()

        locationManager.simulateLocations([CLLocation(latitude: 13.7563, longitude: 100.5018)])
        await viewModel.locationReportTask?.value
        locationManager.simulateLocations([CLLocation(latitude: 14.0, longitude: 101.0)])
        await viewModel.locationReportTask?.value

        #expect(repository.reportCount == 1)
        #expect(repository.lastReported?.latitude == 13.7563)
    }

    @Test func reportFailureAllowsRetryOnNextFix() async {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let repository = RecordingUserLocationRepository(result: .failure(StubError.feedFailed))
        let viewModel = MapViewModel(
            locationManager: locationManager,
            reportUserLocation: ReportUserLocationUseCase(repository: repository)
        )
        viewModel.onMapTabBecameActive()

        locationManager.simulateLocations([CLLocation(latitude: 13.7563, longitude: 100.5018)])
        await viewModel.locationReportTask?.value
        #expect(repository.reportCount == 1)

        repository.result = .success(())
        locationManager.simulateLocations([CLLocation(latitude: 14.0, longitude: 101.0)])
        await viewModel.locationReportTask?.value

        #expect(repository.reportCount == 2)
    }

    @Test func skipsReportingWithoutReporter() {
        let locationManager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let viewModel = MapViewModel(locationManager: locationManager)
        viewModel.onMapTabBecameActive()

        locationManager.simulateLocations([CLLocation(latitude: 13.7563, longitude: 100.5018)])

        #expect(viewModel.userCoordinate?.latitude == 13.7563)
        #expect(viewModel.locationReportTask == nil)
    }
}
