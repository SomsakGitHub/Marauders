//
//  MapClipProximityTests.swift
//  MaraudersTests
//

import CoreLocation
import MapKit
import Testing
@testable import Marauders

@MainActor
struct MapClipProximityTests {
    @Test func clipsInVisibleRegionFiltersByDistance() {
        let user = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
        let region = MKCoordinateRegion(
            center: user,
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        let near = FeedVideo(
            streamURL: URL(string: "https://example.com/near.mp4")!,
            latitude: 13.76,
            longitude: 100.50
        )
        let far = FeedVideo(
            streamURL: URL(string: "https://example.com/far.mp4")!,
            latitude: 14.5,
            longitude: 101.5
        )

        let filtered = MapClipProximity.clips(in: region, from: [near, far])

        #expect(filtered.count == 1)
        #expect(filtered[0].id == near.id)
    }

    @Test func nearMeRegionIsCenteredOnUserAndCoversDefaultRadius() {
        let user = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
        let region = MapClipProximity.region(centeredOn: user)
        let radius = MapClipProximity.defaultNearMeRadiusMeters
        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let north = CLLocation(
            latitude: user.latitude + region.span.latitudeDelta / 2,
            longitude: user.longitude
        )
        let east = CLLocation(
            latitude: user.latitude,
            longitude: user.longitude + region.span.longitudeDelta / 2
        )

        #expect(abs(region.center.latitude - user.latitude) < 0.000001)
        #expect(abs(region.center.longitude - user.longitude) < 0.000001)
        #expect(abs(userLocation.distance(from: north) - radius) < 100)
        #expect(abs(userLocation.distance(from: east) - radius) < 100)
    }

    @Test func formattedDistanceUsesMetersOrKilometers() {
        #expect(MapClipProximity.formattedDistance(450) == "450 m away")
        #expect(MapClipProximity.formattedDistance(2_500) == "2.5 km away")
    }

    @Test func distanceMetersFromUserToClip() {
        let user = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
        let clip = FeedVideo(
            streamURL: URL(string: "https://example.com/a.mp4")!,
            latitude: 13.7563,
            longitude: 100.5018
        )
        let meters = MapClipProximity.distanceMeters(from: user, to: clip)
        #expect(meters != nil)
        #expect(meters! < 1)
    }
}
