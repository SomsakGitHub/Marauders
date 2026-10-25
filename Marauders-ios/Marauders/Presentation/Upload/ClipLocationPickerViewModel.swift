//
//  ClipLocationPickerViewModel.swift
//  Marauders
//

import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

struct PlaceSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor
@Observable
final class ClipLocationPickerViewModel {
    var searchQuery = ""
    var isSearching = false
    var searchError: String?
    private(set) var searchResults: [PlaceSearchResult] = []
    private(set) var selectedPlaceName: String?
    private var generation = 0
    private var activeSearch: MKLocalSearch?
    private var lastRequestedQuery: String?
    private let searchProvider: ((String, CLLocationCoordinate2D) async throws -> [PlaceSearchResult])?

    private(set) var selectedCoordinate: CLLocationCoordinate2D
    var mapPosition: MapCameraPosition

    init(initial: ClipLocation?, searchProvider: ((String, CLLocationCoordinate2D) async throws -> [PlaceSearchResult])? = nil) {
        self.searchProvider = searchProvider
        let coordinate = initial.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? Self.defaultCoordinate
        selectedCoordinate = coordinate
        mapPosition = .region(Self.region(center: coordinate))
    }

    func movePin(to coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        selectedCoordinate = coordinate
        selectedPlaceName = nil
        searchError = nil
    }

    func cancelSearch() {
        generation += 1
        activeSearch?.cancel()
        activeSearch = nil
        lastRequestedQuery = nil
        isSearching = false
        searchResults = []
        searchError = nil
    }

    func select(_ result: PlaceSearchResult) {
        cancelSearch()
        movePin(to: result.coordinate)
        selectedPlaceName = result.name
        mapPosition = .region(Self.region(center: result.coordinate, spanDelta: 0.04))
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query.count <= 120 else {
            searchError = "Enter 2–120 characters to search"
            return
        }
        guard query != lastRequestedQuery || (!isSearching && searchResults.isEmpty) else { return }
        generation += 1
        let requestGeneration = generation
        activeSearch?.cancel()
        lastRequestedQuery = query
        isSearching = true
        searchError = nil
        defer { if generation == requestGeneration { isSearching = false } }
        do {
            let results: [PlaceSearchResult]
            if let searchProvider {
                results = try await searchProvider(query, selectedCoordinate)
            } else {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = MKCoordinateRegion(center: selectedCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
                let search = MKLocalSearch(request: request)
                activeSearch = search
                let response = try await search.start()
                results = response.mapItems.prefix(8).compactMap { item in
                    let coordinate = item.location.coordinate
                    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                    return PlaceSearchResult(name: item.name ?? query,
                        address: item.address?.fullAddress ?? "", coordinate: coordinate)
                }
            }
            guard !Task.isCancelled, generation == requestGeneration,
                  query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            searchResults = Array(results.prefix(8))
            searchError = searchResults.isEmpty ? "No places found — try a name, city or address" : nil
        } catch {
            guard !Task.isCancelled, generation == requestGeneration,
                  query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            searchResults = []
            searchError = "Search failed — try again"
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
