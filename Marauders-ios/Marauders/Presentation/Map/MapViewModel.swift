//
//  MapViewModel.swift
//  Marauders
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class MapViewModel {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var userCoordinate: CLLocationCoordinate2D?
    private(set) var cameraCenterGeneration = 0

    /// Selected country filter for map pins (`nil` shows every country).
    var countryFilter: String?

    var showLocationDeniedAlert = false

    private let locationManager: LocationManaging
    private let delegateBridge = LocationManagerDelegateBridge()
    private let reportUserLocation: ReportUserLocationUseCase?
    private var isLocationServicesAttached = false
    private var wantsUserLocationUpdate = false
    private var hasReportedLocationThisSession = false

    /// In-flight location-report upload (exposed for tests).
    private(set) var locationReportTask: Task<Void, Never>?

    init(
        locationManager: LocationManaging = CLLocationManager(),
        reportUserLocation: ReportUserLocationUseCase? = nil
    ) {
        self.locationManager = locationManager
        self.reportUserLocation = reportUserLocation
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
            requestSystemLocationPermission()
        case .authorizedAlways, .authorizedWhenInUse:
            onMapTabBecameActive()
        case .denied, .restricted:
            showLocationDeniedAlert = true
        @unknown default:
            break
        }
    }

    private func requestSystemLocationPermission() {
        wantsUserLocationUpdate = true
        attachLocationServicesIfNeeded()
        locationManager.requestWhenInUseAuthorization()
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

    private func attachLocationServicesIfNeeded() {
        guard !isLocationServicesAttached, !AppRuntimeConfiguration.isUITesting else { return }
        isLocationServicesAttached = true

        delegateBridge.onAuthorizationChange = { [weak self] in
            self?.handleAuthorizationChange()
        }
        delegateBridge.onLocations = { [weak self] locations in
            self?.handleLocations(locations)
        }
        delegateBridge.onFailure = { error in
            AppLog.warning("map", "location update failed: \(error.localizedDescription)")
        }

        locationManager.delegate = delegateBridge
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func handleAuthorizationChange() {
        authorizationStatus = locationManager.authorizationStatus
        guard wantsUserLocationUpdate, canShowUserOnMap else { return }
        wantsUserLocationUpdate = false
        locationManager.requestLocation()
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard let location = locations.last else { return }
        applyUserCoordinate(location.coordinate)
        reportLocationIfNeeded(location.coordinate)
    }

    /// Persists the user's location to the backend, once per app session.
    private func reportLocationIfNeeded(_ coordinate: CLLocationCoordinate2D) {
        guard !hasReportedLocationThisSession,
              !AppRuntimeConfiguration.isUITesting,
              let reportUserLocation,
              let clipLocation = ClipLocation(
                  latitude: coordinate.latitude,
                  longitude: coordinate.longitude
              )
        else { return }

        hasReportedLocationThisSession = true
        locationReportTask = Task {
            do {
                try await reportUserLocation.execute(location: clipLocation)
                AppLog.info("map", "user location reported")
            } catch {
                self.hasReportedLocationThisSession = false
                AppLog.warning("map", "user location report failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyUserCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        userCoordinate = coordinate
        cameraCenterGeneration += 1
    }

    private static let uiTestCoordinate = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
}
