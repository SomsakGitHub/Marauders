//
//  AVAssetVideoLocationReaderTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@MainActor
struct AVAssetVideoLocationReaderTests {
    @Test func parsesDecimalDegreesWithAltitude() {
        let location = AVAssetVideoLocationReader.parseISO6709("+13.7563+100.5018+010.000/")
        #expect(location?.latitude == 13.7563)
        #expect(location?.longitude == 100.5018)
    }

    @Test func parsesSouthernAndEasternHemispheres() {
        let location = AVAssetVideoLocationReader.parseISO6709("-33.8688+151.2093/")
        #expect(location?.latitude == -33.8688)
        #expect(location?.longitude == 151.2093)
    }

    @Test func rejectsGarbage() {
        #expect(AVAssetVideoLocationReader.parseISO6709("not a location") == nil)
        #expect(AVAssetVideoLocationReader.parseISO6709("") == nil)
    }

    @Test func rejectsOutOfRangeCoordinates() {
        #expect(AVAssetVideoLocationReader.parseISO6709("+999.0+999.0/") == nil)
    }
}
