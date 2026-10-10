//
//  ClipLocationPickerViewModel.swift
//  Marauders
//

import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipLocationPickerViewModel {
    var searchQuery = ""
    var isSearching = false
    var searchError: String?

    private(set) var selectedCoordinate: CLLocationCoordinate2D
    var mapPosition: MapCameraPosition

    init(initial: ClipLocation?) {
        let coordinate = initial.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? Self.defaultCoordinate
        selectedCoordinate = coordinate
        mapPosition = .region(Self.region(center: coordinate))
    }

    func movePin(to coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        selectedCoordinate = coordinate
        searchError = nil
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query.count <= 120 else {
            searchError = "Enter at least 2 characters to search"
            return
        }

        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: selectedCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first,
                  let coordinate = item.placemark.location?.coordinate
            else {
                searchError = "No places found"
                return
            }
            movePin(to: coordinate)
            mapPosition = .region(Self.region(center: coordinate, spanDelta: 0.04))
        } catch {
            searchError = "Search failed — try again"
            AppLog.warning("upload", "place search failed")
        }
    }

    func confirmedClipLocation() -> ClipLocation? {
        ClipLocation(latitude: selectedCoordinate.latitude, longitude: selectedCoordinate.longitude)
    }

    private static let defaultCoordinate = CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)

    private static func region(
        center: CLLocationCoordinate2D,
        spanDelta: Double = 0.08
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        )
    }
}
