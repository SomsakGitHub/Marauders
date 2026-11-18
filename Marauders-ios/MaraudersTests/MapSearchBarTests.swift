//
//  MapSearchBarTests.swift
//  MaraudersTests
//

import SwiftUI
import Testing

@testable import Marauders

@MainActor
struct MapSearchBarTests {
    /// The prompt is a plain `String` (the field takes it as it is), so it is localized where it is made.
    @Test func theSearchPillAsksForClipsByDefault() {
        #expect(MapSearchBar(text: .constant("")).prompt == "Search clips")
    }
}
