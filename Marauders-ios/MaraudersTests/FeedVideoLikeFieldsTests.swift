//
//  FeedVideoLikeFieldsTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct FeedVideoLikeFieldsTests {
    private static func decode(_ json: String) throws -> FeedVideo {
        try JSONDecoder().decode(FeedVideo.self, from: Data(json.utf8))
    }

    private static let id = "11111111-1111-4111-8111-111111111111"

    @Test func theWorkersLikeFieldsAreDecoded() throws {
        let video = try Self.decode(
            #"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4","likeCount":12,"likedByViewer":true}"#
        )
        #expect(video.likeCount == 12)
        #expect(video.likedByViewer == true)
    }

    /// A Worker that predates likes, or a feed cached before them, sends neither field.
    @Test func aFeedWithoutThemStillDecodes() throws {
        let video = try Self.decode(#"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4"}"#)
        #expect(video.likeCount == nil)
        #expect(video.likedByViewer == nil)
    }

    @Test func theFieldsSurviveTheStartupCacheRoundTrip() throws {
        let original = FeedVideo(
            id: UUID(uuidString: Self.id)!,
            streamURL: URL(string: "https://cdn.example.com/a.mp4")!,
            likeCount: 3,
            likedByViewer: false
        )
        let decoded = try JSONDecoder().decode(FeedVideo.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
