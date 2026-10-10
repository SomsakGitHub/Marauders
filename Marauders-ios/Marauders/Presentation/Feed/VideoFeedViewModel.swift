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
    /// Set by coordinator when opening a clip from the map; consumed by `VideoFeedView`.
    var focusVideoID: UUID?

    private let fetchFeed: FetchFeedUseCase
    private var reloadGeneration = 0
    private var initialLoadTask: Task<Void, Never>?

    init(fetchFeed: FetchFeedUseCase) {
        self.fetchFeed = fetchFeed
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

        do {
            let items = try await fetchFeed.execute()
            guard generation == reloadGeneration else { return }
            guard !items.isEmpty else {
                videos = []
                loadState = .failed("Feed is empty — try uploading a clip")
                AppLog.warning("feed", "reload returned empty list")
                return
            }
            videos = items
            loadState = .loaded
            AppLog.info("feed", "reload OK count=\(items.count) topId=\(items.first?.id.uuidString ?? "-")")
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
}
