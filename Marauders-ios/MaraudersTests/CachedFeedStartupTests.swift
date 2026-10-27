import Foundation
import Testing
@testable import Marauders

@MainActor
private final class MemoryStartupCache: FeedStartupCaching {
    let clips: [FeedVideo]
    init(_ clips: [FeedVideo]) { self.clips = clips }
    func cachedVideos() async -> [FeedVideo] { clips }
    private(set) var stored: [FeedVideo] = []
    private(set) var storeCount = 0
    private var storedSignal: CheckedContinuation<Void, Never>?
    func store(_ videos: [FeedVideo]) async {
        stored = videos
        storeCount += 1
        storedSignal?.resume()
        storedSignal = nil
    }
    func waitForStore() async {
        if storeCount > 0 { return }
        await withCheckedContinuation { storedSignal = $0 }
    }
}

private actor StartupRefreshGate: FeedRepository {
    let page: FeedPage
    private var waiting: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(page: FeedPage) { self.page = page }
    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        await withCheckedContinuation { continuation in
            waiting = continuation
            started?.resume()
            started = nil
        }
        return page
    }
    func waitForRequest() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor
struct CachedFeedStartupTests {
    /// A cached clip stays where it is on screen, but shows what the server says about it now.
    @Test func cachedClipShowsTheServersCurrentHandleAfterTheRefresh() async throws {
        let id = UUID()
        let url = URL(string: "https://example.com/cached.mp4")!
        let stale = FeedVideo(id: id, streamURL: url, authorName: "@old")
        let current = FeedVideo(id: id, streamURL: url, authorName: "@new")
        let fresh = FeedVideo(streamURL: URL(string: "https://example.com/fresh.mp4")!)
        let repository = StartupRefreshGate(page: FeedPage(items: [fresh, current], hasMore: false))
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repository),
                                          startupCache: MemoryStartupCache([stale]))
        await viewModel.loadIfNeeded()
        #expect(viewModel.videos == [stale])
        await repository.waitForRequest()
        await repository.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while viewModel.videos.count == 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.videos.map(\.id) == [id, fresh.id])
        #expect(viewModel.videos.first?.authorName == "@new")
    }

    @Test func restoresWithoutWaitingForNetworkAndKeepsDisplayedClipOnRefresh() async throws {
        let cached = FeedVideo(streamURL: URL(string: "https://example.com/cached.mp4")!)
        let fresh = FeedVideo(streamURL: URL(string: "https://example.com/fresh.mp4")!)
        let repository = StartupRefreshGate(page: FeedPage(items: [fresh, cached], hasMore: false))
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repository),
                                          startupCache: MemoryStartupCache([cached]))
        await viewModel.loadIfNeeded()
        #expect(viewModel.videos == [cached])
        #expect(viewModel.restoredStartupCache)
        #expect(viewModel.loadState == .loaded)
        await repository.waitForRequest()
        await repository.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while viewModel.videos.count == 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.videos == [cached, fresh])
        #expect(viewModel.loadState == .loaded)
    }
    @Test func cacheFillSurvivesCallerCancellationAndUsesOnlyUpcomingClips() async {
        let clips = (0..<3).map { FeedVideo(streamURL: URL(string: "https://example.com/\($0).mp4")!) }
        let cache = MemoryStartupCache([])
        let repository = RecordingFeedRepository(result: .success(FeedPage(items: clips, hasMore: false)))
        let viewModel = VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: repository), startupCache: cache)
        await viewModel.loadIfNeeded()
        let viewTask = Task { @MainActor in viewModel.prepareStartupCache(currentIndex: 0) }
        await viewTask.value
        viewTask.cancel()
        viewModel.prepareStartupCache(currentIndex: 1)
        await cache.waitForStore()
        #expect(cache.stored == Array(clips.dropFirst()))
        #expect(cache.storeCount == 1)
    }

}
