//
//  MapClipProximityTests.swift
//  MaraudersTests
//

import CoreLocation
import Testing
@testable import Marauders

struct MapClipProximityTests {
    @Test func clipsWithinRadiusFiltersByDistance() {
        let user = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
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

        let filtered = MapClipProximity.clips(
            within: 5_000,
            of: user,
            from: [near, far]
        )

        #expect(filtered.count == 1)
        #expect(filtered[0].id == near.id)
    }

    @Test func regionFittingIncludesUserAndClips() {
        let user = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        let clip = FeedVideo(
            streamURL: URL(string: "https://example.com/a.mp4")!,
            latitude: 13.01,
            longitude: 100.02
        )

        let region = MapClipProximity.regionFitting(user: user, clips: [clip])
        #expect(region.center.latitude > 12.99)
        #expect(region.center.latitude < 13.02)
        #expect(region.span.latitudeDelta >= 0.02)
    }
}
