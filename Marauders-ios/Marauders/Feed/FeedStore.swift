//
//  FeedStore.swift
//  Marauders
//

import Foundation
import Observation

enum FeedLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class FeedStore {
    var videos: [FeedVideo] = []
    var loadState: FeedLoadState = .idle

    private let client: FeedAPIClient

    init() {
        client = FeedAPIClient()
    }

    init(client: FeedAPIClient) {
        self.client = client
    }

    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await reload()
    }

    func reload() async {
        AppLog.info("feed", "reload started (currentCount=\(videos.count))")
        loadState = .loading

        do {
            let items = try await client.fetchFeed()
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
            AppLog.error("feed", "reload failed: \(error.localizedDescription)")
            if videos.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                loadState = .loaded
            }
        }
    }
}
