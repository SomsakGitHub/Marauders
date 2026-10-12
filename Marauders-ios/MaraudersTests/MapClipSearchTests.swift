//
//  MapClipSearchTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct MapClipSearchTests {
    private func clip(
        caption: String? = nil,
        authorName: String? = nil,
        country: String? = nil
    ) -> FeedVideo {
        FeedVideo(
            streamURL: URL(string: "https://example.com/clip.mp4")!,
            latitude: 13.7563,
            longitude: 100.5018,
            country: country,
            authorName: authorName,
            caption: caption
        )
    }

    @Test func emptyQueryMatchesEverything() {
        let clips = [clip(caption: "hello"), clip(caption: "world")]
        #expect(MapClipSearch.filter(clips, query: "   ").count == 2)
    }

    @Test func matchesCaptionCaseInsensitively() {
        let clips = [clip(caption: "Sunset in Bangkok"), clip(caption: "Morning run")]
        let results = MapClipSearch.filter(clips, query: "sunset")
        #expect(results.count == 1)
        #expect(results.first?.caption == "Sunset in Bangkok")
    }

    @Test func matchesAuthorHandle() {
        let clips = [clip(authorName: "@marauders"), clip(authorName: "@nomad")]
        let results = MapClipSearch.filter(clips, query: "marauders")
        #expect(results.count == 1)
    }

    @Test func matchesCountryNameAndCode() {
        let clips = [clip(country: "TH"), clip(country: "US")]
        #expect(MapClipSearch.filter(clips, query: "thailand").count == 1)
        #expect(MapClipSearch.filter(clips, query: "us").count == 1)
    }

    @Test func unmatchedQueryReturnsNothing() {
        let clips = [clip(caption: "hello"), clip(authorName: "@someone")]
        #expect(MapClipSearch.filter(clips, query: "zzzz").isEmpty)
    }
}
