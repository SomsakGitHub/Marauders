//
//  MapClipProximity.swift
//  Marauders
//

import CoreLocation
import MapKit

enum MapClipProximity {
    static let defaultNearMeRadiusMeters: CLLocationDistance = NearMeRadius.default.meters

    static func distanceMeters(
        from user: CLLocationCoordinate2D,
        to clip: FeedVideo
    ) -> CLLocationDistance? {
        guard let coordinate = clip.mapCoordinate else { return nil }
        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let clipLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return userLocation.distance(from: clipLocation)
    }

    static func formattedDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1_000 {
            return String(format: "%.0f m away", meters)
        }
        return String(format: "%.1f km away", meters / 1_000)
    }

    static func clips(
        in region: MKCoordinateRegion,
        from clips: [FeedVideo]
    ) -> [FeedVideo] {
        clips.filter { clip in
            guard let coordinate = clip.mapCoordinate else { return false }
            return region.contains(coordinate)
        }
    }

    static func region(
        centeredOn center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance = defaultNearMeRadiusMeters
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )
    }
}
