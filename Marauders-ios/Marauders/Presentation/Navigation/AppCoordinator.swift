//
//  AppCoordinator.swift
//  Marauders
//

import Foundation

/// Application flow orchestration — cross-feature navigation and post-flow side effects.
/// Does not replace ViewModels; handles what spans multiple tabs (e.g. upload → refresh feed → show feed).
@MainActor
final class AppCoordinator {
    let router: AppRouter
    let feedViewModel: VideoFeedViewModel
    let uploadViewModel: UploadVideoViewModel

    init(
        router: AppRouter,
        feedViewModel: VideoFeedViewModel,
        uploadViewModel: UploadVideoViewModel
    ) {
        self.router = router
        self.feedViewModel = feedViewModel
        self.uploadViewModel = uploadViewModel
        uploadViewModel.onUploaded = { [weak self] in
            await self?.handleUploadCompleted()
        }
    }

    func loadFeedIfNeeded() async {
        await feedViewModel.loadIfNeeded()
    }

    func handleUploadCompleted() async {
        await feedViewModel.reload()
        router.showFeed()
        AppLog.info("app", "coordinator: upload complete → feed tab")
    }

    func openClipInFeed(videoID: UUID) async {
        await feedViewModel.loadIfNeeded()
        if !feedViewModel.videos.contains(where: { $0.id == videoID }) {
            await feedViewModel.reload()
        }
        feedViewModel.requestFocus(on: videoID)
        router.showFeed()
        AppLog.info("app", "coordinator: map clip → feed id=\(videoID.uuidString)")
    }
}
