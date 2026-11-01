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
    private let feedRepository: FeedRepository
    private let uploadRepository: VideoUploadRepository
    private let videoExporter: VideoExporting
    private let profileRepository: UserProfileRepository
    private let commentRepository: CommentRepository

    init(
        feedRepository: FeedRepository? = nil,
        uploadRepository: VideoUploadRepository? = nil,
        videoExporter: VideoExporting? = nil,
        profileRepository: UserProfileRepository? = nil,
        commentRepository: CommentRepository? = nil,
        clipLikeRepository: ClipLikeRepository? = nil,
        userFollowRepository: UserFollowRepository? = nil,
        locationSharingRepository: LocationSharingRepository? = nil
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
        let authViewModel = AuthViewModel(sessionStore: sessionStore, tokenStore: tokenStore, signsInAsTestUserOnSimulator: true)
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
        followsViewModel = UserFollowsViewModel(setFollow: SetUserFollowUseCase(repository: resolveUserFollowRepository))

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
        friendLocationsViewModel = FriendLocationsViewModel(
            loadFriends: LoadFriendLocationsUseCase(repository: resolveLocationSharingRepository),
            setSharing: SetLocationSharingUseCase(repository: resolveLocationSharingRepository),
            // UI tests have no location to send; the map there uses a fixed one.
            reporter: AppRuntimeConfiguration.isUITesting ? nil : ForegroundLocationReporter(report: reportUserLocation)
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

    func makePublicProfileViewModel(handle: String) -> PublicProfileViewModel {
        PublicProfileViewModel(
            handle: handle,
            loadProfile: LoadPublicProfileUseCase(repository: profileRepository),
            follows: followsViewModel
        )
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
