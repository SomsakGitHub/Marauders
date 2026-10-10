//
//  ClipLocationPickerViewModelTests.swift
//  MaraudersTests
//

import CoreLocation
import Testing
@testable import Marauders

@MainActor
struct ClipLocationPickerViewModelTests {
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
