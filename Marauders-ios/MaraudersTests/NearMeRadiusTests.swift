//
//  NearMeRadiusTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders

/// The two texts a radius makes, in English (the unit tests run in English). The unit stays metric in every language.
@MainActor
struct NearMeRadiusTests {
    @Test func everyRadiusNamesItselfInKilometres() {
        #expect(NearMeRadius.fiveKm.label == "5 km")
        #expect(NearMeRadius.twentyFiveKm.label == "25 km")
        #expect(NearMeRadius.fiftyKm.label == "50 km")
    }

    @Test func anEmptyMapSaysHowFarItLooked() {
        #expect(NearMeRadius.fiveKm.emptyClipsMessage == "No clips within 5 km")
        #expect(NearMeRadius.twentyFiveKm.emptyClipsMessage == "No clips within 25 km")
        #expect(NearMeRadius.fiftyKm.emptyClipsMessage == "No clips within 50 km")
    }
}
