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
    private var isLocationServicesAttached = false
    private var wantsUserLocationUpdate = false

    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        if AppRuntimeConfiguration.isUITesting {
            authorizationStatus = .authorizedWhenInUse
        } else {
            authorizationStatus = locationManager.authorizationStatus
        }
    }

    /// Map tab is shown only when location is authorized.
    var canAccessMap: Bool {
        canShowUserOnMap
    }

    var canShowUserOnMap: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    var isLocationAccessDeniedOrRestricted: Bool {
        switch authorizationStatus {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    func syncAuthorizationStatusFromSystem() {
        guard !AppRuntimeConfiguration.isUITesting else { return }
        authorizationStatus = locationManager.authorizationStatus
    }

    /// Gate screen: start the permission flow.
    func beginLocationAccessRequest() {
        if AppRuntimeConfiguration.isUITesting {
            applyUserCoordinate(Self.uiTestCoordinate)
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            showLocationPrePrompt = true
        case .authorizedAlways, .authorizedWhenInUse:
            onMapTabBecameActive()
        case .denied, .restricted:
            showLocationDeniedAlert = true
        @unknown default:
            break
        }
    }

    func confirmLocationPermissionRequest() {
        showLocationPrePrompt = false
        wantsUserLocationUpdate = true
        attachLocationServicesIfNeeded()
        locationManager.requestWhenInUseAuthorization()
    }

    func cancelLocationPermissionRequest() {
        showLocationPrePrompt = false
        wantsUserLocationUpdate = false
    }

    /// Called when the Map tab is visible and location is already granted.
    func onMapTabBecameActive() {
        syncAuthorizationStatusFromSystem()
        guard canShowUserOnMap else { return }

        if AppRuntimeConfiguration.isUITesting {
            applyUserCoordinate(Self.uiTestCoordinate)
            return
        }

        wantsUserLocationUpdate = true
        attachLocationServicesIfNeeded()
        locationManager.requestLocation()
    }

    func currentLocationButtonTapped() {
        if AppRuntimeConfiguration.isUITesting {
            applyUserCoordinate(Self.uiTestCoordinate)
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            beginLocationAccessRequest()
        case .authorizedAlways, .authorizedWhenInUse:
            wantsUserLocationUpdate = true
            attachLocationServicesIfNeeded()
            locationManager.requestLocation()
        case .denied, .restricted:
            showLocationDeniedAlert = true
        @unknown default:
            break
        }
    }

    func regionForCameraCenter() -> MKCoordinateRegion? {
        guard let coordinate = userCoordinate else { return nil }
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    }

    private func attachLocationServicesIfNeeded() {
        guard !isLocationServicesAttached, !AppRuntimeConfiguration.isUITesting else { return }
        isLocationServicesAttached = true

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
        guard wantsUserLocationUpdate, canShowUserOnMap else { return }
        wantsUserLocationUpdate = false
        manager.requestLocation()
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
