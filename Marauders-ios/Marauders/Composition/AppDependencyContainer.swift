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
    let profileViewModel: ProfileViewModel
    let reportUserLocation: ReportUserLocationUseCase
    private let feedRepository: FeedRepository
    private let uploadRepository: VideoUploadRepository
    private let videoExporter: VideoExporting
    private let profileRepository: UserProfileRepository

    init(
        feedRepository: FeedRepository? = nil,
        uploadRepository: VideoUploadRepository? = nil,
        videoExporter: VideoExporting? = nil,
        profileRepository: UserProfileRepository? = nil
    ) {
        let uiTestFeedMode = Self.uiTestFeedMode()
        let sessionStore: AuthSessionStore
        let tokenStore: APIAccessTokenStore
        let baseTransport: HTTPClient
        let usesRejectedUITestSession = UITestRejectedSession.isRequested
        if usesRejectedUITestSession {
            let rejectedSession = UITestRejectedSession()
            sessionStore = rejectedSession
            tokenStore = rejectedSession
            baseTransport = UITestRejectingHTTPClient()
        } else {
            sessionStore = KeychainAuthSessionStore()
            tokenStore = KeychainAPIAccessTokenStore()
            baseTransport = AlamofireHTTPClient()
        }
        let authViewModel = AuthViewModel(sessionStore: sessionStore, tokenStore: tokenStore)
        let apiAuthorization = SessionAPIAuthorization(tokenStore: tokenStore)
        // Every API client talks through this one, so the Worker answering 401 to a request that carried the session's
        // token ends the session in one place, AuthViewModel, instead of in each client and screen.
        let transport = RejectedSessionReportingHTTPClient(base: baseTransport) { accessToken in
            await authViewModel.handleRejectedAccessToken(accessToken)
        }

        if let feedRepository {
            self.feedRepository = feedRepository
        } else if AppRuntimeConfiguration.isUITesting {
            self.feedRepository = UITestFeedRepository(mode: uiTestFeedMode)
        } else {
            self.feedRepository = DefaultFeedRepository(apiClient: FeedAPIClient(
                client: transport,
                authorization: apiAuthorization
            ))
        }

        self.uploadRepository = uploadRepository ?? DefaultVideoUploadRepository(
            apiClient: VideoUploadAPIClient(client: transport, authorization: apiAuthorization)
        )
        self.videoExporter = videoExporter ?? DefaultVideoExporter()

        self.reportUserLocation = ReportUserLocationUseCase(
            repository: DefaultUserLocationRepository(
                apiClient: UserLocationAPIClient(client: transport, authorization: apiAuthorization)
            )
        )

        let fetchFeed = FetchFeedUseCase(repository: self.feedRepository)
        feedViewModel = VideoFeedViewModel(
            fetchFeed: fetchFeed,
            startupCache: AppRuntimeConfiguration.isUITesting || feedRepository != nil ? nil : FeedStartupCache.shared
        )

        let prepare = PrepareVideoForUploadUseCase(exporter: self.videoExporter)
        let upload = UploadFeedVideoUseCase(repository: self.uploadRepository)
        uploadViewModel = UploadVideoViewModel(
            prepareVideo: prepare,
            uploadVideo: upload,
            videoLocationReader: AVAssetVideoLocationReader()
        )
        self.authViewModel = authViewModel

        let resolveProfileRepository: UserProfileRepository
        if let profileRepository {
            resolveProfileRepository = profileRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            resolveProfileRepository = UITestUserProfileRepository()
        } else {
            resolveProfileRepository = DefaultUserProfileRepository(
                apiClient: UserProfileAPIClient(client: transport, authorization: apiAuthorization)
            )
        }
        self.profileRepository = resolveProfileRepository
        profileViewModel = ProfileViewModel(
            loadProfile: LoadUserProfileUseCase(repository: resolveProfileRepository),
            deleteClip: DeleteUserClipUseCase(repository: resolveProfileRepository),
            updateHandle: UpdateUserHandleUseCase(repository: resolveProfileRepository),
            updateAvatar: UpdateAvatarUseCase(
                repository: resolveProfileRepository,
                imagePreparer: DefaultAvatarImagePreparer()
            )
        )

        coordinator = AppCoordinator(
            router: router,
            feedViewModel: feedViewModel,
            uploadViewModel: uploadViewModel
        )

        profileViewModel.onHandleChanged = { [weak feedViewModel] oldHandle, newHandle in
            feedViewModel?.replaceAuthorName(from: oldHandle, to: newHandle)
        }
        profileViewModel.onAvatarChanged = { [weak feedViewModel] url, handle in
            feedViewModel?.applyAuthorAvatar(url: url, for: handle)
        }
        profileViewModel.onClipDeleted = { [weak feedViewModel] clipID in
            Task { @MainActor in await feedViewModel?.removeClip(id: clipID) }
        }
    }

    func makePublicProfileViewModel(handle: String) -> PublicProfileViewModel {
        PublicProfileViewModel(
            handle: handle,
            loadProfile: LoadPublicProfileUseCase(repository: profileRepository)
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
