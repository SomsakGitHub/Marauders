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
        loadState = .loading

        do {
            let items = try await client.fetchFeed()
            guard !items.isEmpty else {
                videos = []
                loadState = .failed("ฟีดว่าง — ลองอัปโหลดคลิปใหม่")
                return
            }
            videos = items
            loadState = .loaded
        } catch {
            if videos.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                loadState = .loaded
            }
        }
    }
}
