//
//  FeedMediaPreparationServiceTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

struct FeedMediaPreparationServiceTests {
    @Test func beginPlaybackItemRejectsNonHTTPS() async throws {
        let service = FeedMediaPreparationService()
        let item = try await service.beginPlaybackItem(
            for: URL(string: "http://cdn.example.com/video.mp4")!
        )
        #expect(item == nil)
    }

    @Test func prefetchIgnoresNonHTTPS() async {
        let service = FeedMediaPreparationService()
        await service.prefetch(url: URL(string: "ftp://example.com/a.mp4")!, protected: [])
        let cached = await service.consumePreparedItem(
            for: URL(string: "ftp://example.com/a.mp4")!
        )
        #expect(cached == nil)
    }
}
