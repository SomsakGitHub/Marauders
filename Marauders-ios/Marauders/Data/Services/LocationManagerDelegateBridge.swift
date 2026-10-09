//
//  LocationManagerDelegateBridge.swift
//  Marauders
//

import CoreLocation
import Foundation

final class LocationManagerDelegateBridge: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: ((CLLocationManager) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailure?(error)
    }
}
