//
//  MapClipClusteringTests.swift
//  Marauders
//

import CoreLocation
import MapKit
import Testing

@testable import Marauders

@MainActor
struct MapClipClusteringTests {
    private let bangkok = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    private func clip(latitude: Double, longitude: Double, author: String? = nil) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/\(latitude)-\(longitude).mp4")!,
                  latitude: latitude,
                  longitude: longitude,
                  authorName: author)
    }

    @Test func clipsWithoutCoordinatesAreIgnored() {
        let withoutCoordinate = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let clusters = MapClipClustering.clusters(from: [withoutCoordinate], in: region)
        #expect(clusters.isEmpty)
    }

    @Test func singleClipBecomesItsOwnCluster() {
        let clusters = MapClipClustering.clusters(
            from: [clip(latitude: bangkok.latitude, longitude: bangkok.longitude)],
            in: region
        )
        #expect(clusters.count == 1)
        #expect(clusters.first?.isCluster == false)
        #expect(clusters.first?.clips.count == 1)
    }

    @Test func nearbyClipsCollapseIntoOneCluster() {
        let clips = [
            clip(latitude: 13.7563, longitude: 100.5018),
            clip(latitude: 13.7565, longitude: 100.5020),
            clip(latitude: 13.7564, longitude: 100.5016),
        ]
        let clusters = MapClipClustering.clusters(from: clips, in: region)
        #expect(clusters.count == 1)
        #expect(clusters.first?.isCluster == true)
        #expect(clusters.first?.clips.count == 3)
    }

    @Test func sameUserClipsAtTheSameLocationKeepTheMostRecentlyPostedClip() {
        let newest = clip(latitude: 13.672, longitude: 100.60, author: "@somsak")
        let older = clip(latitude: 13.672, longitude: 100.60, author: "@somsak")
        let oldest = clip(latitude: 13.6719, longitude: 100.5999, author: "@somsak")

        let clusters = MapClipClustering.clusters(from: [newest, older, oldest], in: region)

        #expect(clusters.count == 1)
        #expect(clusters.first?.isCluster == false)
        #expect(clusters.first?.clips.count == 1)
        #expect(clusters.first?.clips.first?.id == newest.id)
    }

    @Test func differentUsersAtTheSameLocationStaySeparate() {
        let first = clip(latitude: 13.672, longitude: 100.60, author: "@somsak")
        let second = clip(latitude: 13.672, longitude: 100.60, author: "@someone")

        let clusters = MapClipClustering.clusters(from: [first, second], in: region)

        #expect(clusters.count == 1)
        #expect(clusters.first?.isCluster == true)
        #expect(clusters.first?.clips.count == 2)
    }

    @Test func sameUserClipsFarApartStaySeparate() {
        let near = clip(latitude: 13.672, longitude: 100.60, author: "@somsak")
        let far = clip(latitude: 13.80, longitude: 100.58, author: "@somsak")

        let clusters = MapClipClustering.clusters(from: [near, far], in: region)

        #expect(clusters.count == 2)
    }

    @Test func distantClipsStaySeparate() {
        let clips = [
            clip(latitude: 13.7563, longitude: 100.5018),
            clip(latitude: 13.85, longitude: 100.62),
        ]
        let clusters = MapClipClustering.clusters(from: clips, in: region)
        #expect(clusters.count == 2)
    }

    @Test func zoomingInSplitsAClusterApart() {
        let clips = [
            clip(latitude: 13.7500, longitude: 100.5000),
            clip(latitude: 13.7600, longitude: 100.5100)
        ]
        let wide = MKCoordinateRegion(
            center: bangkok,
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
        )
        let tight = MKCoordinateRegion(
            center: bangkok,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )

        #expect(MapClipClustering.clusters(from: clips, in: wide).count == 1)
        #expect(MapClipClustering.clusters(from: clips, in: tight).count == 2)
    }

    @Test func clusterCoordinateIsCentroidOfMembers() {
        let clusters = MapClipClustering.clusters(
            from: [
                clip(latitude: 10, longitude: 20),
                clip(latitude: 10.0001, longitude: 20.0001),
            ],
            in: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 10, longitude: 20),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        )
        let coordinate = try? #require(clusters.first?.coordinate)
        #expect(coordinate?.latitude ?? 0 == 10.00005)
    }

    @Test func largerClustersSortFirst() {
        let clips = [
            clip(latitude: 0, longitude: 0),
            clip(latitude: 0.0001, longitude: 0),
            clip(latitude: 0.5, longitude: 0.5),
        ]
        let clusters = MapClipClustering.clusters(from: clips, in: region)
        #expect(clusters.first?.clips.count == 2)
    }
}
