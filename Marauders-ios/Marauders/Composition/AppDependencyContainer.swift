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
    let authViewModel: AuthViewModel
    private let feedRepository: FeedRepository
    private let uploadRepository: VideoUploadRepository
    private let videoExporter: VideoExporting

    init(
        feedRepository: FeedRepository? = nil,
        uploadRepository: VideoUploadRepository? = nil,
        videoExporter: VideoExporting? = nil
    ) {
        let uiTestFeedMode = Self.uiTestFeedMode()
        if let feedRepository {
            self.feedRepository = feedRepository
        } else if AppRuntimeConfiguration.isUITesting {
            self.feedRepository = UITestFeedRepository(mode: uiTestFeedMode)
        } else {
            self.feedRepository = DefaultFeedRepository(apiClient: FeedAPIClient())
        }
        self.uploadRepository = uploadRepository ?? DefaultVideoUploadRepository(apiClient: VideoUploadAPIClient())
        self.videoExporter = videoExporter ?? DefaultVideoExporter()

        let fetchFeed = FetchFeedUseCase(repository: self.feedRepository)
        feedViewModel = VideoFeedViewModel(fetchFeed: fetchFeed)

        let prepare = PrepareVideoForUploadUseCase(exporter: self.videoExporter)
        let upload = UploadFeedVideoUseCase(repository: self.uploadRepository)
        uploadViewModel = UploadVideoViewModel(prepareVideo: prepare, uploadVideo: upload)
        authViewModel = AuthViewModel()

        coordinator = AppCoordinator(
            router: router,
            feedViewModel: feedViewModel,
            uploadViewModel: uploadViewModel
        )
    }

    private static func uiTestFeedMode() -> UITestFeedMode {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        if arguments.contains("UITEST_EMPTY_FEED") || environment["UITEST_EMPTY_FEED"] == "1" {
            return .mockEmpty
        }
        return .mockPopulated
    }
}
