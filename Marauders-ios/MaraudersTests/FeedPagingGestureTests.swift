import AVFoundation
import Testing
import UIKit
@testable import Marauders

@MainActor
struct FeedPagingGestureTests {
    @Test func surfacesStayOnTheirOwnPagesDuringForwardAndReverseScroll() throws {
        let urls = (0..<3).map { URL(string: "https://example.com/\($0).mp4")! }
        let view = VerticalFeedPagingView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        view.setVideos(urls, scrollToIndex: 0)
        let first = AVPlayerLayer()
        let second = AVPlayerLayer()
        view.syncPresentations([
            FeedPlayerPresentation(id: 0, url: urls[0], layer: first),
            FeedPlayerPresentation(id: 1, url: urls[1], layer: second)
        ])
        let scroll = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        let firstHost = try #require(first.superlayer?.delegate as? FeedPlayerLayerHostView)
        let secondHost = try #require(second.superlayer?.delegate as? FeedPlayerLayerHostView)
        #expect(firstHost.frame.minY == 0)
        #expect(secondHost.frame.minY == 640)
        scroll.contentOffset.y = 320
        #expect(firstHost.convert(firstHost.bounds, to: view).minY == -320)
        #expect(secondHost.convert(secondHost.bounds, to: view).minY == 320)
        view.setVideos(urls, scrollToIndex: 1)
        #expect(firstHost.frame.minY == 0)
        #expect(secondHost.frame.minY == 640)
        scroll.contentOffset.y = 320
        #expect(firstHost.convert(firstHost.bounds, to: view).minY == -320)
        #expect(secondHost.convert(secondHost.bounds, to: view).minY == 320)
    }

    @Test func playerPoolRetainsPreviousAndNextWithoutMovingTheirSurfaces() {
        let urls = (0..<4).map { URL(string: "https://example.com/\($0).mp4")! }
        let engine = FeedPlayerEngine()
        engine.settle(on: urls[0], prefetchNeighbors: [urls[1], urls[2]])
        let original = engine.presentations.first { $0.url == urls[0] }?.layer
        engine.settle(on: urls[1], prefetchNeighbors: [urls[2], urls[0]])
        #expect(engine.presentations.count == 3)
        #expect(engine.presentations.first { $0.url == urls[0] }?.layer === original)
        #expect(Set(engine.presentations.compactMap(\.url)) == Set(urls.prefix(3)))
        engine.settle(on: urls[2], prefetchNeighbors: [urls[3], urls[1]])
        #expect(Set(engine.presentations.compactMap(\.url)) == Set(urls.suffix(3)))
        #expect(engine.presentations.count == 3)
    }

    @Test func previewTargetsAreBoundedAndExcludeDuplicateOrInsecureURLs() {
        let current = URL(string: "https://example.com/current.mp4")!
        let next = URL(string: "https://example.com/next.mp4")!
        let previous = URL(string: "https://example.com/previous.mp4")!
        #expect(FeedPlayerEngine.previewTargets(currentURL: current, neighbors: [
            current, URL(string: "http://example.com/bad.mp4")!, next, next, previous,
            URL(string: "https://example.com/distant.mp4")!
        ]) == [next, previous])
    }
}
