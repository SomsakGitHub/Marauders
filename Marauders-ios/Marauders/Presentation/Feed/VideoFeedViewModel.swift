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

    private let fetchFeed: FetchFeedUseCase
    private var reloadGeneration = 0

    init(fetchFeed: FetchFeedUseCase) {
        self.fetchFeed = fetchFeed
    }

    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await reload()
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
                loadState = .failed("ฟีดว่าง — ลองอัปโหลดคลิปใหม่")
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
