//
//  LocationManagerDelegateBridge.swift
//  Marauders
//

import CoreLocation
import Foundation

final class LocationManagerDelegateBridge: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: (@MainActor () -> Void)?
    var onLocations: (@MainActor ([CLLocation]) -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailure?(error)
    }
}
