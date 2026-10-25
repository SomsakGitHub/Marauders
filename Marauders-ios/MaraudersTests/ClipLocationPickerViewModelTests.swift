//
//  ClipLocationPickerViewModelTests.swift
//  MaraudersTests
//

import CoreLocation
import Testing
@testable import Marauders

@MainActor
struct ClipLocationPickerViewModelTests {
    @Test func resultsDoNotMovePinUntilAPlaceIsSelected() async {
        let result = PlaceSearchResult(name: "CentralWorld", address: "Bangkok", coordinate: .init(latitude: 13.746, longitude: 100.539))
        let model = ClipLocationPickerViewModel(initial: nil, searchProvider: { _, _ in [result] })
        let original = model.selectedCoordinate
        model.searchQuery = "CentralWorld"
        await model.search()
        #expect(model.searchResults.count == 1)
        #expect(model.selectedCoordinate.latitude == original.latitude)
        #expect(model.selectedCoordinate.longitude == original.longitude)
        model.select(result)
        #expect(model.selectedCoordinate.latitude == result.coordinate.latitude)
        #expect(model.selectedCoordinate.longitude == result.coordinate.longitude)
        #expect(model.selectedPlaceName == result.name)
        #expect(model.searchResults.isEmpty)
    }

    @Test func lateSearchCannotReplaceNewQueryResults() async throws {
        let model = ClipLocationPickerViewModel(initial: nil, searchProvider: { query, _ in
            if query == "Old place" { try? await Task.sleep(for: .milliseconds(60)) }
            return [PlaceSearchResult(name: query, address: "", coordinate: .init(latitude: 13, longitude: 100))]
        })
        model.searchQuery = "Old place"
        let old = Task { await model.search() }
        try await Task.sleep(for: .milliseconds(10))
        model.searchQuery = "New place"
        model.cancelSearch()
        await model.search()
        await old.value
        #expect(model.searchResults.first?.name == "New place")
        model.cancelSearch()
        #expect(model.searchResults.isEmpty)
        #expect(!model.isSearching)
    }

    @Test func movePinUpdatesCoordinate() {
        let viewModel = ClipLocationPickerViewModel(initial: nil)
        let target = CLLocationCoordinate2D(latitude: 14.0, longitude: 101.0)

        viewModel.movePin(to: target)

        #expect(viewModel.selectedCoordinate.latitude == 14.0)
        #expect(viewModel.selectedCoordinate.longitude == 101.0)
        #expect(viewModel.confirmedClipLocation() != nil)
    }

    @Test func searchRejectsShortQuery() async {
        let viewModel = ClipLocationPickerViewModel(initial: nil)
        viewModel.searchQuery = "a"

        await viewModel.search()

        #expect(viewModel.searchError != nil)
    }
}
