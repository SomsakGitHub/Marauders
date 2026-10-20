//
//  MapClipClustering.swift
//  Marauders
//

import CoreLocation
import MapKit

/// A group of one or more clips rendered as a single map pin.
struct MapClipCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let clips: [FeedVideo]

    var isCluster: Bool { clips.count > 1 }

    var representative: FeedVideo { clips[0] }
}

/// Collapses nearby clips into clusters so the map stays readable when zoomed
/// out, mirroring the pin-grouping behaviour of Instagram's map. When the same
/// user posts several clips from the same spot, only the most recently posted
/// one is shown instead of a cluster that could never be zoomed apart.
enum MapClipClustering {
    /// Clips posted by the same user within this distance of each other are
    /// treated as being at the same location.
    static let sameAuthorLocationThresholdMeters: CLLocationDistance = 50
    /// Groups clips that fall inside the same grid cell of the current visible
    /// region. Zooming in shrinks each cell, which naturally breaks clusters
    /// apart again.
    static func clusters(
        from clips: [FeedVideo],
        in region: MKCoordinateRegion,
        columns: Int = 6,
        rows: Int = 8
    ) -> [MapClipCluster] {
        let columnCount = max(1, columns)
        let rowCount = max(1, rows)
        let latitudeStep = region.span.latitudeDelta / Double(rowCount)
        let longitudeStep = region.span.longitudeDelta / Double(columnCount)
        guard latitudeStep > 0, longitudeStep > 0 else { return [] }

        var buckets: [String: [FeedVideo]] = [:]
        var keptLocationsByAuthor: [String: [CLLocationCoordinate2D]] = [:]
        for clip in clips {
            guard let coordinate = clip.mapCoordinate else { continue }

            // When the same user posts several clips from the same spot, show
            // only the most recently posted one (the feed is ordered
            // newest-first). Different users at the same spot stay separate.
            if let author = clip.authorName, !author.isEmpty {
                let keptLocations = keptLocationsByAuthor[author, default: []]
                let isSameLocation = keptLocations.contains {
                    distance(from: $0, to: coordinate) <= Self.sameAuthorLocationThresholdMeters
                }
                guard !isSameLocation else { continue }
                keptLocationsByAuthor[author] = keptLocations + [coordinate]
            }

            let row = Int((coordinate.latitude / latitudeStep).rounded(.down))
            let column = Int((coordinate.longitude / longitudeStep).rounded(.down))
            buckets["\(row):\(column)", default: []].append(clip)
        }

        return buckets.values
            .compactMap { grouped -> MapClipCluster? in
                guard let coordinate = averageCoordinate(of: grouped) else { return nil }
                let id = grouped
                    .map { $0.id.uuidString }
                    .sorted()
                    .joined(separator: "|")
                return MapClipCluster(
                    id: id,
                    coordinate: coordinate,
                    clips: grouped.sorted { $0.id.uuidString < $1.id.uuidString }
                )
            }
            .sorted { lhs, rhs in
                if lhs.clips.count != rhs.clips.count {
                    return lhs.clips.count > rhs.clips.count
                }
                return lhs.id < rhs.id
            }
    }

    private static func distance(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    private static func averageCoordinate(of clips: [FeedVideo]) -> CLLocationCoordinate2D? {
        let coordinates = clips.compactMap(\.mapCoordinate)
        guard !coordinates.isEmpty else { return nil }
        let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MKCoordinateRegion {
    /// Whether the region contains the coordinate, using the live span so an
    /// annotation just outside the visible area is excluded.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitudeDelta = span.latitudeDelta / 2
        let longitudeDelta = span.longitudeDelta / 2
        let latitudeInRange = abs(coordinate.latitude - center.latitude) <= latitudeDelta
        let longitudeInRange = abs(coordinate.longitude - center.longitude) <= longitudeDelta
        return latitudeInRange && longitudeInRange
    }
}
