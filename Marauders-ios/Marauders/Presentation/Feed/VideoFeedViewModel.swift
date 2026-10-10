//
//  VideoFeedViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class VideoFeedViewModel {
    var videos: [FeedVideo] = []
    var loadState: FeedLoadState = .idle
    private(set) var isLoadingMore = false
    /// Set by coordinator when opening a clip from the map; consumed by `VideoFeedView`.
    var focusVideoID: UUID?

    private let fetchFeed: FetchFeedUseCase
    private let pageSize: Int
    private var reloadGeneration = 0
    private var initialLoadTask: Task<Void, Never>?
    private var hasMorePages = false
    private var isLoadingMoreInFlight = false
    private let maxPagesWhenResolvingVideo = 50

    init(fetchFeed: FetchFeedUseCase, pageSize: Int = 20) {
        self.fetchFeed = fetchFeed
        self.pageSize = pageSize
    }

    /// Waits until the first feed load finishes (splash / cold start).
    func awaitInitialLoad() async {
        if let initialLoadTask {
            await initialLoadTask.value
            return
        }
        await loadIfNeeded()
        if let initialLoadTask {
            await initialLoadTask.value
        }
    }

    func loadIfNeeded() async {
        if loadState != .idle {
            await initialLoadTask?.value
            return
        }
        let task = Task { @MainActor in
            await reload()
        }
        initialLoadTask = task
        await task.value
    }

    func requestFocus(on videoID: UUID) {
        focusVideoID = videoID
    }

    func consumeFocusRequest() -> UUID? {
        let id = focusVideoID
        focusVideoID = nil
        return id
    }

    var videosWithMapCoordinates: [FeedVideo] {
        videos.filter { $0.mapCoordinate != nil }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration

        AppLog.info("feed", "reload started (currentCount=\(videos.count))")
        loadState = .loading
        isLoadingMore = false
        isLoadingMoreInFlight = false

        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: nil)
            guard generation == reloadGeneration else { return }
            guard !page.items.isEmpty else {
                videos = []
                hasMorePages = false
                loadState = .failed("Feed is empty — try uploading a clip")
                AppLog.warning("feed", "reload returned empty list")
                return
            }
            videos = page.items
            hasMorePages = page.hasMore
            loadState = .loaded
            AppLog.info(
                "feed",
                "reload OK count=\(page.items.count) hasMore=\(page.hasMore) topId=\(page.items.first?.id.uuidString ?? "-")"
            )
        } catch {
            guard generation == reloadGeneration else { return }
            AppLog.error("feed", "reload failed: \(error.localizedDescription)")
            if videos.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                loadState = .loaded
            }
        }
    }

    /// Fetches the latest page from the server and merges new clips at the top (map pins / after upload).
    func syncHeadWithServer() async {
        guard loadState == .loaded else {
            await loadIfNeeded()
            return
        }

        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: nil)
            mergeHead(page.items)
            hasMorePages = page.hasMore || videos.count > page.items.count
            AppLog.info("feed", "syncHead merged count=\(videos.count) mapPins=\(videosWithMapCoordinates.count)")
        } catch {
            AppLog.warning("feed", "syncHead failed: \(error.localizedDescription)")
        }
    }

    func loadMoreIfNearEnd(currentIndex: Int) async {
        guard loadState == .loaded, hasMorePages, !isLoadingMoreInFlight else { return }
        let triggerIndex = max(0, videos.count - 3)
        guard currentIndex >= triggerIndex else { return }
        await loadNextPage()
    }

    /// Loads additional feed pages until `videoID` appears (e.g. opening a map pin deep in the feed).
    @discardableResult
    func ensureVideoLoaded(videoID: UUID) async -> Bool {
        if videos.contains(where: { $0.id == videoID }) { return true }

        await loadIfNeeded()
        if videos.contains(where: { $0.id == videoID }) { return true }

        if await paginateUntilFound(videoID: videoID) { return true }

        await reload()
        if videos.contains(where: { $0.id == videoID }) { return true }
        if await paginateUntilFound(videoID: videoID) { return true }

        AppLog.warning("feed", "ensureVideoLoaded missed id=\(videoID.uuidString)")
        return false
    }

    private func paginateUntilFound(videoID: UUID) async -> Bool {
        var pagesFetched = 0
        while hasMorePages, pagesFetched < maxPagesWhenResolvingVideo {
            pagesFetched += 1
            await loadNextPage()
            if videos.contains(where: { $0.id == videoID }) { return true }
        }
        return false
    }

    private func loadNextPage() async {
        guard let cursor = videos.last?.id else { return }

        isLoadingMoreInFlight = true
        isLoadingMore = true
        defer {
            isLoadingMoreInFlight = false
            isLoadingMore = false
        }

        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: cursor)
            appendUnique(page.items)
            hasMorePages = page.hasMore
            AppLog.info("feed", "loadMore +\(page.items.count) total=\(videos.count) hasMore=\(page.hasMore)")
        } catch {
            AppLog.warning("feed", "loadMore failed: \(error.localizedDescription)")
        }
    }

    private func mergeHead(_ headItems: [FeedVideo]) {
        guard !headItems.isEmpty else { return }
        let headIDs = Set(headItems.map(\.id))
        let tail = videos.filter { !headIDs.contains($0.id) }
        videos = headItems + tail
    }

    private func appendUnique(_ newItems: [FeedVideo]) {
        guard !newItems.isEmpty else {
            hasMorePages = false
            return
        }
        let existing = Set(videos.map(\.id))
        let toAppend = newItems.filter { !existing.contains($0.id) }
        videos.append(contentsOf: toAppend)
    }
}
