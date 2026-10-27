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
        uploadViewModel.onUploaded = { [weak self] uploaded in
            await self?.handleUploadCompleted(uploaded: uploaded)
        }
    }

    func loadFeedIfNeeded() async {
        await feedViewModel.loadIfNeeded()
    }

    /// Reloads the feed, which now includes the viewer's own clips, and brings the new clip into view.
    func handleUploadCompleted(uploaded: FeedVideo? = nil) async {
        await feedViewModel.reload()
        if let uploaded, feedViewModel.videos.contains(where: { $0.id == uploaded.id }) {
            feedViewModel.requestFocus(on: uploaded.id)
        }
        router.showFeed()
        AppLog.info("app", "coordinator: upload complete → feed tab")
    }

    func openClipInFeed(videoID: UUID) async {
        let found = await feedViewModel.ensureVideoLoaded(videoID: videoID)
        if found {
            feedViewModel.requestFocus(on: videoID)
            AppLog.info("app", "coordinator: map clip → feed id=\(videoID.uuidString)")
        } else {
            AppLog.warning("app", "coordinator: map clip not in feed id=\(videoID.uuidString)")
        }
        router.showFeed()
    }
}
