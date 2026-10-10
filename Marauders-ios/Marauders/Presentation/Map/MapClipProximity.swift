//
//  MapClipProximity.swift
//  Marauders
//

import CoreLocation
import MapKit

enum MapClipProximity {
    static let defaultNearMeRadiusMeters: CLLocationDistance = 25_000

    static func clips(
        within radiusMeters: CLLocationDistance,
        of user: CLLocationCoordinate2D,
        from clips: [FeedVideo]
    ) -> [FeedVideo] {
        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        return clips.filter { clip in
            guard let coordinate = clip.mapCoordinate else { return false }
            let clipLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return userLocation.distance(from: clipLocation) <= radiusMeters
        }
    }

    static func regionFitting(
        user: CLLocationCoordinate2D,
        clips: [FeedVideo],
        minimumSpanDelta: CLLocationDegrees = 0.02
    ) -> MKCoordinateRegion {
        var coordinates = clips.compactMap(\.mapCoordinate)
        coordinates.append(user)

        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: user,
                span: MKCoordinateSpan(latitudeDelta: minimumSpanDelta, longitudeDelta: minimumSpanDelta)
            )
        }

        let first = coordinates[0]
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latitudeDelta = max(minimumSpanDelta, (maxLat - minLat) * 1.5)
        let longitudeDelta = max(minimumSpanDelta, (maxLon - minLon) * 1.5)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}
