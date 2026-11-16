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
    let clipLikesViewModel: ClipLikesViewModel
    let followsViewModel: UserFollowsViewModel
    let friendLocationsViewModel: FriendLocationsViewModel
    /// The saved AI audio that viewers share, which every clip player's dubbing view model reads and writes. It is not
    /// behind `transport`, so a 401 on its routes does not end the session; it does trade a token the Worker rejected
    /// for a new one, like every client that sends the session's token.
    private let dubbedAudioCache: any DubbedAudioCaching
    /// The on-device engines that find a clip's language, write its speech down and read the translation aloud.
    private let dubbingServices = DubbingServices.onDevice()
    /// The Settings screen's list of on-device language models and how far each download has got.
    let languageModelsViewModel = LanguageModelsViewModel(manager: AppleLanguageModelManager())
    /// Which listening languages this iPhone cannot serve, which `AppRootView` puts in the environment for the picker.
    let listeningLanguageAvailability: any ListeningLanguageAvailability = SystemListeningLanguageAvailability()
    private let feedRepository: FeedRepository
    private let videoExporter: VideoExporting
    private let profileRepository: UserProfileRepository
    private let commentRepository: CommentRepository
    private let followListRepository: FollowListRepository

    init(
        feedRepository: FeedRepository? = nil,
        videoExporter: VideoExporting? = nil,
        profileRepository: UserProfileRepository? = nil,
        commentRepository: CommentRepository? = nil,
        clipLikeRepository: ClipLikeRepository? = nil,
        userFollowRepository: UserFollowRepository? = nil,
        locationSharingRepository: LocationSharingRepository? = nil,
        followListRepository: FollowListRepository? = nil
    ) {
        let uiTestFeedMode = Self.uiTestFeedMode()
        let sessionStore: AuthSessionStore
        let tokenStore: APIAccessTokenStore
        let refreshTokenStore: APIRefreshTokenStore
        let baseTransport: HTTPClient
        let refresher: any TokenRefreshing
        let usesRejectedUITestSession = UITestRejectedSession.isRequested
        if usesRejectedUITestSession {
            let rejectedSession = UITestRejectedSession()
            sessionStore = rejectedSession
            tokenStore = rejectedSession
            refreshTokenStore = rejectedSession
            baseTransport = UITestRejectingHTTPClient()
            // Over the same in-memory stores: no refresh token in them, so the 401 ends the session.
            refresher = TokenRefresher(
                accessTokenStore: rejectedSession, refreshTokenStore: rejectedSession, authAPI: AuthAPIClient())
        } else {
            sessionStore = KeychainAuthSessionStore()
            tokenStore = KeychainAPIAccessTokenStore()
            refreshTokenStore = KeychainAPIRefreshTokenStore()
            baseTransport = URLSessionHTTPClient()
            refresher = Self.tokenRefresher
        }
        dubbedAudioCache = DubbedAudioCacheClient(
            client: APITransportComposition.quiet(base: URLSessionHTTPClient(), refresher: Self.tokenRefresher))
        #if DEBUG
            let devAuth: (any DevAuthExchanging)? = DevAuthAPIClient()
        #else
            let devAuth: (any DevAuthExchanging)? = nil
        #endif
        let authViewModel = AuthViewModel(
            sessionStore: sessionStore, tokenStore: tokenStore, refreshTokenStore: refreshTokenStore,
            authAPI: AuthAPIClient(), devAuth: devAuth, signsInAsTestUserOnSimulator: true)
        let apiAuthorization = SessionAPIAuthorization(tokenStore: tokenStore)
        // Every API client talks through this one, so the Worker answering 401 to a request that carried the session's
        // token ends the session in one place, AuthViewModel, instead of in each client and screen.
        let reportRejected: @Sendable (String) async -> Void = { accessToken in
            await authViewModel.handleRejectedAccessToken(accessToken)
        }
        // A 401 goes to the refresh layer first, which trades the token for a new one and sends the request again.
        // Only a session that cannot be saved reaches the reporter as a 401. Reads are repeated on a transient failure
        // below both, so a 401 is never retried.
        let transport = APITransportComposition.api(
            base: baseTransport, refresher: refresher, reportRejected: reportRejected)
        // The feed repeats its own reads (FeedAPIClient), so it gets no second layer of retries.
        let feedTransport = APITransportComposition.feed(
            base: baseTransport, refresher: refresher, reportRejected: reportRejected)

        if let feedRepository {
            self.feedRepository = feedRepository
        } else if AppRuntimeConfiguration.isUITesting {
            self.feedRepository = UITestFeedRepository(mode: uiTestFeedMode)
        } else {
            self.feedRepository = DefaultFeedRepository(
                apiClient: FeedAPIClient(
                    client: feedTransport,
                    authorization: apiAuthorization
                ))
        }

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
        uploadViewModel = UploadVideoViewModel(
            prepareVideo: prepare,
            videoLocationReader: AVAssetVideoLocationReader(),
            audioInspector: FastClipAudioInspector()
        )
        self.authViewModel = authViewModel

        // UI tests share one in-memory set of follows between the follow button and the profiles that report them.
        let uiTestFollows = UITestUserFollowRepository()
        let resolveUserFollowRepository: UserFollowRepository
        if let userFollowRepository {
            resolveUserFollowRepository = userFollowRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            resolveUserFollowRepository = uiTestFollows
        } else {
            resolveUserFollowRepository = DefaultUserFollowRepository(
                apiClient: FollowsAPIClient(client: transport, authorization: apiAuthorization)
            )
        }
        followsViewModel = UserFollowsViewModel(
            setFollow: SetUserFollowUseCase(repository: resolveUserFollowRepository))

        let resolveLocationSharingRepository: LocationSharingRepository
        if let locationSharingRepository {
            resolveLocationSharingRepository = locationSharingRepository
        } else if AppRuntimeConfiguration.isUITesting {
            // The rejected-session UI tests too: the check at launch would end their session before what they test.
            resolveLocationSharingRepository = UITestLocationSharingRepository(follows: uiTestFollows)
        } else {
            resolveLocationSharingRepository = DefaultLocationSharingRepository(
                apiClient: LocationSharingAPIClient(client: transport, authorization: apiAuthorization)
            )
        }
        // A sign out first switches the viewer's location sharing off on the Worker, which needs the token it is about to
        // clear. Set here, not in the initializer: the repository talks through the transport, which reports back to it.
        authViewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(
            repository: resolveLocationSharingRepository)
        friendLocationsViewModel = FriendLocationsViewModel(
            loadFriends: LoadFriendLocationsUseCase(repository: resolveLocationSharingRepository),
            setSharing: SetLocationSharingUseCase(repository: resolveLocationSharingRepository),
            // UI tests have no location to send; the map there uses a fixed one.
            reporter: AppRuntimeConfiguration.isUITesting
                ? nil : ForegroundLocationReporter(report: reportUserLocation),
            backgroundMonitor: AppRuntimeConfiguration.isUITesting ? nil : Self.backgroundLocationMonitor
        )

        let resolveProfileRepository: UserProfileRepository
        if let profileRepository {
            resolveProfileRepository = profileRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            resolveProfileRepository = UITestUserProfileRepository(follows: uiTestFollows)
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

        if let commentRepository {
            self.commentRepository = commentRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            self.commentRepository = UITestCommentRepository()
        } else {
            self.commentRepository = DefaultCommentRepository(
                apiClient: CommentsAPIClient(client: transport, authorization: apiAuthorization)
            )
        }

        if let followListRepository {
            self.followListRepository = followListRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            self.followListRepository = UITestFollowListRepository(follows: uiTestFollows)
        } else {
            self.followListRepository = DefaultFollowListRepository(
                apiClient: FollowListAPIClient(client: transport, authorization: apiAuthorization)
            )
        }

        let resolveClipLikeRepository: ClipLikeRepository
        if let clipLikeRepository {
            resolveClipLikeRepository = clipLikeRepository
        } else if AppRuntimeConfiguration.isUITesting, !usesRejectedUITestSession {
            resolveClipLikeRepository = UITestClipLikeRepository()
        } else {
            resolveClipLikeRepository = DefaultClipLikeRepository(
                apiClient: LikesAPIClient(client: transport, authorization: apiAuthorization)
            )
        }
        clipLikesViewModel = ClipLikesViewModel(setLike: SetClipLikeUseCase(repository: resolveClipLikeRepository))

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
        followsViewModel.onViewerFollowingCountChange = { [weak profileViewModel] count in
            profileViewModel?.applyFollowingCount(count)
        }
    }

    /// The one refresher of the process. Every transport asks this one, the monitor that runs while the app is closed
    /// included, because a refresh token is single use: two refreshers in one process could spend it twice and end the
    /// session they were meant to keep. It reads and writes the Keychain, where the session is kept.
    static let tokenRefresher = TokenRefresher(
        accessTokenStore: KeychainAPIAccessTokenStore(),
        refreshTokenStore: KeychainAPIRefreshTokenStore(),
        authAPI: AuthAPIClient()
    )

    /// The one monitor that sends the viewer's location while the app is closed. `MaraudersApp` starts it at launch,
    /// before any container exists (iOS may launch the app in the background just to hand over a location), so it
    /// reaches the Worker on its own: a 401 that a refresh cannot heal stops it instead of ending the session, which
    /// the next launch's own requests do. A day-old token is healed, so it keeps sending past its first day.
    static let backgroundLocationMonitor = BackgroundLocationMonitor(
        report: ReportUserLocationUseCase(
            repository: DefaultUserLocationRepository(
                apiClient: UserLocationAPIClient(
                    client: APITransportComposition.quiet(base: URLSessionHTTPClient(), refresher: tokenRefresher),
                    authorization: SessionAPIAuthorization(tokenStore: KeychainAPIAccessTokenStore())
                )
            )
        )
    )

    func makePublicProfileViewModel(handle: String) -> PublicProfileViewModel {
        PublicProfileViewModel(
            handle: handle,
            loadProfile: LoadPublicProfileUseCase(repository: profileRepository),
            follows: followsViewModel
        )
    }

    func makeFollowListViewModel(handle: String, kind: FollowListKind) -> FollowListViewModel {
        FollowListViewModel(
            handle: handle,
            kind: kind,
            loadList: LoadFollowListUseCase(repository: followListRepository)
        )
    }

    /// What the screens that push profiles and follower lists need, in one value for the Profile tab and the profile
    /// sheet, so both push the same screens against the same follows and the same session.
    var profileNavigation: ProfileNavigation {
        ProfileNavigation(
            authViewModel: authViewModel,
            followsViewModel: followsViewModel,
            makePublicProfileViewModel: { [self] in makePublicProfileViewModel(handle: $0) },
            makeFollowListViewModel: { [self] in makeFollowListViewModel(handle: $0, kind: $1) }
        )
    }

    /// A view model that dubs one clip, which the clip player owns while the clip is open. `AppRootView` puts this in the
    /// environment, because a player creates its view model before it can read the cache and the services from it.
    func makeDubbingViewModel() -> DubbingViewModel {
        DubbingViewModel(cache: dubbedAudioCache, services: dubbingServices)
    }

    func makeCommentsViewModel(videoID: UUID) -> CommentsViewModel {
        CommentsViewModel(
            videoID: videoID,
            loadComments: LoadCommentsUseCase(repository: commentRepository),
            postComment: PostCommentUseCase(repository: commentRepository),
            deleteComment: DeleteCommentUseCase(repository: commentRepository)
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
