//
//  ClipCommentCountsTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct ClipCommentCountsTests {
    private static let url = URL(string: "https://cdn.example.com/a.mp4")!
    private static let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func clip(_ count: Int?, id: UUID = ClipCommentCountsTests.id) -> FeedVideo {
        FeedVideo(id: id, streamURL: Self.url, commentCount: count)
    }

    // MARK: - What the feed says

    @Test func aClipNobodyHasCommentedOnHereShowsWhatTheFeedSaid() {
        let counts = ClipCommentCounts()

        #expect(counts.count(for: clip(4)) == 4)
        #expect(counts.count(for: clip(0)) == 0)
    }

    /// A Worker from before comment counts sends none: the rail then says "Comments" instead of a number.
    @Test func aFeedWithoutACountShowsNone() {
        var counts = ClipCommentCounts()

        counts.record(1, on: clip(nil))

        #expect(counts.count(for: clip(nil)) == nil)
    }

    @Test func aCountBelowZeroFromTheFeedShowsAsZero() {
        #expect(ClipCommentCounts().count(for: clip(-3)) == 0)
    }

    // MARK: - What the viewer did

    @Test func postsAndDeletesAddUpOnTopOfTheFeedsCount() {
        var counts = ClipCommentCounts()

        counts.record(1, on: clip(4))
        #expect(counts.count(for: clip(4)) == 5)
        counts.record(1, on: clip(4))
        counts.record(-1, on: clip(4))
        #expect(counts.count(for: clip(4)) == 5)
    }

    @Test func theCountNeverGoesBelowZeroAndComesBackUpFromThere() {
        var counts = ClipCommentCounts()

        counts.record(-1, on: clip(1))
        counts.record(-1, on: clip(1))
        #expect(counts.count(for: clip(1)) == 0)
        counts.record(1, on: clip(1))
        #expect(counts.count(for: clip(1)) == 1)
    }

    @Test func eachClipKeepsItsOwnCount() {
        var counts = ClipCommentCounts()
        let other = UUID()

        counts.record(1, on: clip(2))

        #expect(counts.count(for: clip(2, id: other)) == 2)
        #expect(counts.count(for: clip(2)) == 3)
    }

    // MARK: - A newer feed

    /// A reload that says something else about the clip is newer, and already holds what the viewer posted.
    @Test func aReloadWithAnotherCountWins() {
        var counts = ClipCommentCounts()
        counts.record(1, on: clip(4))

        #expect(counts.count(for: clip(5)) == 5)
        #expect(counts.count(for: clip(9)) == 9)
    }

    @Test func aChangeAfterAReloadStartsFromTheReloadsCount() {
        var counts = ClipCommentCounts()
        counts.record(1, on: clip(4))

        counts.record(1, on: clip(7))

        #expect(counts.count(for: clip(7)) == 8)
    }

    // MARK: - The feed's field

    @Test func theWorkersCommentCountIsDecoded() throws {
        let json = #"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4","commentCount":12}"#
        let video = try JSONDecoder().decode(FeedVideo.self, from: Data(json.utf8))

        #expect(video.commentCount == 12)
    }

    /// A Worker that predates comment counts, or a feed cached before them, sends no count.
    @Test func aFeedWithoutTheCountStillDecodes() throws {
        let json = #"{"id":"\#(Self.id)","streamURL":"https://cdn.example.com/a.mp4"}"#
        let video = try JSONDecoder().decode(FeedVideo.self, from: Data(json.utf8))

        #expect(video.commentCount == nil)
    }

    @Test func theCountSurvivesTheStartupCacheRoundTrip() throws {
        let original = clip(6)

        let decoded = try JSONDecoder().decode(FeedVideo.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.commentCount == 6)
    }
}
