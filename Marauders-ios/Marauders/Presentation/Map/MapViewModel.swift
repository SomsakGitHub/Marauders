//
//  MapViewModel.swift
//  Marauders
//

import CoreLocation
import Foundation
import MapKit
import Observation

@MainActor
@Observable
final class MapViewModel {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var userCoordinate: CLLocationCoordinate2D?
    private(set) var cameraCenterGeneration = 0

    var showLocationPrePrompt = false
    var showLocationDeniedAlert = false

    private let locationManager: CLLocationManager
    private let delegateBridge = LocationManagerDelegateBridge()

    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        if AppRuntimeConfiguration.isUITesting {
            authorizationStatus = .authorizedWhenInUse
        } else {
            authorizationStatus = locationManager.authorizationStatus
        }
        configureLocationManagerIfNeeded()
    }

    var canShowUserOnMap: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    func currentLocationButtonTapped() {
        if AppRuntimeConfiguration.isUITesting {
            applyUserCoordinate(Self.uiTestCoordinate)
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            showLocationPrePrompt = true
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied, .restricted:
            showLocationDeniedAlert = true
        @unknown default:
            break
        }
    }

    func confirmLocationPermissionRequest() {
        showLocationPrePrompt = false
        locationManager.requestWhenInUseAuthorization()
    }

    func cancelLocationPermissionRequest() {
        showLocationPrePrompt = false
    }

    func regionForCameraCenter() -> MKCoordinateRegion? {
        guard let coordinate = userCoordinate else { return nil }
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    }

    private func configureLocationManagerIfNeeded() {
        guard !AppRuntimeConfiguration.isUITesting else { return }

        delegateBridge.onAuthorizationChange = { [weak self] manager in
            Task { @MainActor in
                self?.handleAuthorizationChange(manager)
            }
        }
        delegateBridge.onLocations = { [weak self] locations in
            Task { @MainActor in
                self?.handleLocations(locations)
            }
        }
        delegateBridge.onFailure = { [weak self] error in
            Task { @MainActor in
                AppLog.warning("map", "location update failed: \(error.localizedDescription)")
            }
        }

        locationManager.delegate = delegateBridge
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func handleAuthorizationChange(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if canShowUserOnMap {
            manager.requestLocation()
        }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard let location = locations.last else { return }
        applyUserCoordinate(location.coordinate)
    }

    private func applyUserCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        userCoordinate = coordinate
        cameraCenterGeneration += 1
    }

    private static let uiTestCoordinate = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
}
