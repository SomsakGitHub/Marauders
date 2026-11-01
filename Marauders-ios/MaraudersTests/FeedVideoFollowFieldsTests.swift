//
//  FeedVideoFollowFieldsTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct FeedVideoFollowFieldsTests {
    private static func decode(_ json: String) throws -> FeedVideo {
        try JSONDecoder().decode(FeedVideo.self, from: Data(json.utf8))
    }

    private static let id = "11111111-1111-4111-8111-111111111111"

    @Test func theWorkersFollowFieldsAreDecoded() throws {
        let video = try Self.decode(
            #"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4","postedByViewer":false,"authorFollowedByViewer":true}"#
        )
        #expect(video.postedByViewer == false)
        #expect(video.authorFollowedByViewer == true)
    }

    /// A Worker that predates follows, or a feed cached before them, sends neither field: the avatar then has no "+".
    @Test func aFeedWithoutThemStillDecodes() throws {
        let video = try Self.decode(#"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4"}"#)
        #expect(video.postedByViewer == nil)
        #expect(video.authorFollowedByViewer == nil)
    }

    @Test func theFieldsSurviveTheStartupCacheRoundTrip() throws {
        let original = FeedVideo(
            id: UUID(uuidString: Self.id)!,
            streamURL: URL(string: "https://cdn.example.com/a.mp4")!,
            postedByViewer: true,
            authorFollowedByViewer: false
        )
        let decoded = try JSONDecoder().decode(FeedVideo.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test(arguments: [("@Alice", "@alice"), ("alice", "@alice"), (" @bob_1 ", "@bob_1"), ("@x.y", "@x.y")])
    func handlesAreKeyedTheWayTheWorkerStoresThem(raw: String, normalized: String) {
        #expect(UserHandle.normalized(raw) == normalized)
    }
}
