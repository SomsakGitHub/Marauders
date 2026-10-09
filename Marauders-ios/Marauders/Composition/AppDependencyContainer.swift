//
//  AppDependencyContainer.swift
//  Marauders
//

import Foundation

/// Composition root — wires Domain use cases to Data implementations (Clean Architecture).
@MainActor
final class AppDependencyContainer {
    let router = AppRouter()
    let coordinator: AppCoordinator

    let feedViewModel: VideoFeedViewModel
    let uploadViewModel: UploadVideoViewModel

    private let feedRepository: FeedRepository
    private let uploadRepository: VideoUploadRepository
    private let videoExporter: VideoExporting

    init(
        feedRepository: FeedRepository? = nil,
        uploadRepository: VideoUploadRepository? = nil,
        videoExporter: VideoExporting? = nil
    ) {
        self.feedRepository = feedRepository ?? DefaultFeedRepository(apiClient: FeedAPIClient())
        self.uploadRepository = uploadRepository ?? DefaultVideoUploadRepository(apiClient: VideoUploadAPIClient())
        self.videoExporter = videoExporter ?? DefaultVideoExporter()

        let fetchFeed = FetchFeedUseCase(repository: self.feedRepository)
        feedViewModel = VideoFeedViewModel(fetchFeed: fetchFeed)

        let prepare = PrepareVideoForUploadUseCase(exporter: self.videoExporter)
        let upload = UploadFeedVideoUseCase(repository: self.uploadRepository)
        uploadViewModel = UploadVideoViewModel(prepareVideo: prepare, uploadVideo: upload)

        coordinator = AppCoordinator(
            router: router,
            feedViewModel: feedViewModel,
            uploadViewModel: uploadViewModel
        )
    }
}
