//
//  VideoFeedViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class VideoFeedViewModel {
    private(set) var sessionGeneration = 0
    var videos: [FeedVideo] = []
    var loadState: FeedLoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var restoredStartupCache = false
    /// Clips fetched for a specific country (Map tab). Empty when no filter is active.
    private(set) var mapFilteredClips: [FeedVideo] = []
    /// Set by coordinator when opening a clip from the map; consumed by `VideoFeedView`.
    var focusVideoID: UUID?

    private let fetchFeed: FetchFeedUseCase
    private let startupCache: (any FeedStartupCaching)?
    private var didScheduleStartupCache = false
    private var startupCacheTask: Task<Void, Never>?
    private let pageSize: Int
    private var reloadGeneration = 0
    private var initialLoadTask: Task<Void, Never>?
    private var hasMorePages = false
    private var isLoadingMoreInFlight = false
    private let maxPagesWhenResolvingVideo = 50

    init(fetchFeed: FetchFeedUseCase, pageSize: Int = 20, startupCache: (any FeedStartupCaching)? = nil) {
        self.startupCache = startupCache
        self.fetchFeed = fetchFeed
        self.pageSize = pageSize
    }

    func resetForSessionChange() {
        sessionGeneration += 1
        reloadGeneration += 1
        initialLoadTask?.cancel()
        initialLoadTask = nil
        startupCacheTask?.cancel()
        startupCacheTask = nil
        didScheduleStartupCache = false
        restoredStartupCache = false
        videos = []
        mapFilteredClips = []
        focusVideoID = nil
        hasMorePages = false
        isLoadingMore = false
        isLoadingMoreInFlight = false
        loadState = .idle
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
        // Share the task even before reload() gets its first MainActor turn.
        if let initialLoadTask {
            await initialLoadTask.value
            return
        }
        guard loadState == .idle else { return }
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let generation = reloadGeneration
            if let cached = await startupCache?.cachedVideos(), !cached.isEmpty,
               generation == reloadGeneration, loadState == .idle {
                restoredStartupCache = true
                videos = cached
                loadState = .loaded
                AppLog.info("startup.cache", "restored clips=\(cached.count)")
                Task { await refreshAfterCachedStart(cached, generation: generation) }
            } else if generation == reloadGeneration {
                await reload()
            }
        }
        initialLoadTask = task
        await task.value
    }

    /// Fill shortly after playback starts; loop transitions must not cancel the download.
    func prepareStartupCache(currentIndex: Int) {
        guard !didScheduleStartupCache, let startupCache, videos.indices.contains(currentIndex) else { return }
        didScheduleStartupCache = true
        let upcoming = Array(videos.dropFirst(currentIndex + 1).prefix(2))
        let candidates = upcoming.isEmpty ? [videos[currentIndex]] : upcoming
        startupCacheTask = Task(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(3))
                AppLog.info("startup.cache", "fill started clips=\(candidates.count)")
                await startupCache.store(candidates)
            } catch { }
        }
    }

    private func refreshAfterCachedStart(_ cached: [FeedVideo], generation: Int) async {
        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: nil)
            guard reloadGeneration == generation else { return }
            // Keep the displayed cached clip at the same index while refreshing the tail.
            let cachedIDs = Set(cached.map(\.id))
            videos = cached + page.items.filter { !cachedIDs.contains($0.id) }
            hasMorePages = page.hasMore
            AppLog.info("startup.cache", "fresh feed merged")
        } catch {
            guard reloadGeneration == generation else { return }
            hasMorePages = true
            AppLog.debug("startup.cache", "using cached feed while refresh unavailable")
        }
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

    /// Replaces the cached author handle on the signed-in user's own clips after a @handle change,
    /// so the feed reflects the new name without a network round-trip.
    func replaceAuthorName(from oldValue: String, to newValue: String) {
        guard !oldValue.isEmpty, oldValue != newValue else { return }
        videos = videos.map { Self.renamed($0, from: oldValue, to: newValue) }
        mapFilteredClips = mapFilteredClips.map { Self.renamed($0, from: oldValue, to: newValue) }
    }

    private static func renamed(_ video: FeedVideo, from oldValue: String, to newValue: String) -> FeedVideo {
        guard video.authorName == oldValue else { return video }
        return FeedVideo(
            id: video.id,
            streamURL: video.streamURL,
            latitude: video.latitude,
            longitude: video.longitude,
            country: video.country,
            authorName: newValue,
            authorAvatarURL: video.authorAvatarURL,
            caption: video.caption
        )
    }

    /// Updates the avatar shown for the signed-in user's own clips after an avatar change.
    func applyAuthorAvatar(url: URL?, for handle: String) {
        guard !handle.isEmpty else { return }
        videos = videos.map { Self.withAvatar($0, handle: handle, url: url) }
        mapFilteredClips = mapFilteredClips.map { Self.withAvatar($0, handle: handle, url: url) }
    }

    private static func withAvatar(_ video: FeedVideo, handle: String, url: URL?) -> FeedVideo {
        guard video.authorName == handle else { return video }
        return FeedVideo(
            id: video.id,
            streamURL: video.streamURL,
            latitude: video.latitude,
            longitude: video.longitude,
            country: video.country,
            authorName: video.authorName,
            authorAvatarURL: url,
            caption: video.caption
        )
    }

    /// Loads map pins independently of the personalized feed; nil means every country.
    func loadMapClips(country: String?) async {
        let generation = sessionGeneration
        do {
            let page = try await fetchFeed.executeMap(limit: pageSize, country: country)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            mapFilteredClips = page.items.filter { $0.mapCoordinate != nil }
            AppLog.info("feed.map", "country=\(country ?? "all") clips=\(mapFilteredClips.count)")
        } catch {
            AppLog.warning("feed.map", "load failed country=\(country ?? "all"): \(error.localizedDescription)")
        }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let fetchStarted = ProcessInfo.processInfo.systemUptime

        AppLog.info("feed", "reload started (currentCount=\(videos.count))")
        loadState = .loading
        isLoadingMore = false
        isLoadingMoreInFlight = false

        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: nil)
            AppLog.timing("feed.fetch.completed", since: fetchStarted)
            guard generation == reloadGeneration else { return }
            guard !page.items.isEmpty else {
                videos = []
                hasMorePages = false
                loadState = .loaded
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
            AppLog.timing("feed.fetch.failed", since: fetchStarted)
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

        let generation = reloadGeneration
        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: nil)
            guard generation == reloadGeneration else { return }
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
        let generation = reloadGeneration

        isLoadingMoreInFlight = true
        isLoadingMore = true
        defer {
            if generation == reloadGeneration {
                isLoadingMoreInFlight = false
                isLoadingMore = false
            }
        }

        do {
            let page = try await fetchFeed.execute(limit: pageSize, cursor: cursor)
            guard generation == reloadGeneration else { return }
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
