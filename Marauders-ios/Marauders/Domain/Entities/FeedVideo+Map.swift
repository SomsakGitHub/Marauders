//
//  FeedVideo+Map.swift
//  Marauders
//

import CoreLocation
import Foundation

extension FeedVideo {
    var mapCoordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        guard ClipLocation.isValid(latitude: latitude, longitude: longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
