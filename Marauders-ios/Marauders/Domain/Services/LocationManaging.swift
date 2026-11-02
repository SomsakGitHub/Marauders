//
//  LocationManaging.swift
//  Marauders
//

import CoreLocation

/// Minimal seam over `CLLocationManager` so ViewModels can be unit-tested
/// without touching the real system location permission flows.
protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var delegate: CLLocationManagerDelegate? { get set }

    func requestAlwaysAuthorization()
    func requestWhenInUseAuthorization()
    func requestLocation()
}

extension CLLocationManager: LocationManaging {}

/// What `BackgroundLocationMonitor` needs on top: the two services that keep working while the app is closed.
protocol BackgroundLocationManaging: LocationManaging {
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
    func startMonitoringVisits()
    func stopMonitoringVisits()
}

extension CLLocationManager: BackgroundLocationManaging {}
