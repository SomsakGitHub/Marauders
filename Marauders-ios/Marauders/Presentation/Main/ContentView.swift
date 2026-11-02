//
//  ContentView.swift
//  Marauders
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var router: AppRouter
    let coordinator: AppCoordinator
    @Bindable var feedViewModel: VideoFeedViewModel
    @Bindable var uploadViewModel: UploadVideoViewModel
    @Bindable var authViewModel: AuthViewModel
    @Bindable var profileViewModel: ProfileViewModel
    let reportUserLocation: ReportUserLocationUseCase
    let makePublicProfileViewModel: (String) -> PublicProfileViewModel
    let makeCommentsViewModel: (UUID) -> CommentsViewModel
    let clipLikesViewModel: ClipLikesViewModel
    let followsViewModel: UserFollowsViewModel
    let friendLocationsViewModel: FriendLocationsViewModel

    @State private var languageModelsViewModel = LanguageModelsViewModel()
    @State private var showingSignIn = false
    @State private var signInDismissalID = 0

    var body: some View {
        TabView(selection: $router.selectedTab) {
            VideoFeedView(
                viewModel: feedViewModel,
                isFeedTabSelected: router.selectedTab == .feed,
                isSignedIn: authViewModel.isSignedIn,
                onSignIn: { showingSignIn = true },
                signInDismissalID: signInDismissalID,
                onOpenProfile: { router.openPublicProfile(handle: $0) },
                makeCommentsViewModel: makeCommentsViewModel,
                likesViewModel: clipLikesViewModel,
                followsViewModel: followsViewModel
            )
                .tabItem {
                    Label("Feed", systemImage: "play.rectangle.fill")
                }
                .tag(MainTab.feed)

            MapTabView(
                authViewModel: authViewModel,
                feedViewModel: feedViewModel,
                reportUserLocation: reportUserLocation,
                onSignIn: { showingSignIn = true },
                onOpenClipInFeed: { videoID in
                    await coordinator.openClipInFeed(videoID: videoID)
                },
                onOpenProfile: { router.openPublicProfile(handle: $0) },
                friendLocations: friendLocationsViewModel
            )
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(MainTab.map)

            ProfileTabView(
                authViewModel: authViewModel,
                profileViewModel: profileViewModel,
                onSignIn: { showingSignIn = true }
            )
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                .tag(MainTab.profile)

            UploadTabView(
                authViewModel: authViewModel,
                uploadViewModel: uploadViewModel,
                onSignIn: { showingSignIn = true }
            )
                .tabItem {
                    Label("Upload", systemImage: "plus.circle.fill")
                }
                .tag(MainTab.upload)

            SettingsView(
                languageModels: languageModelsViewModel,
                friendLocations: friendLocationsViewModel,
                isSignedIn: authViewModel.isSignedIn
            )
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(MainTab.settings)

            #if DEBUG
            NavigationStack {
                DebugLogView()
            }
            .tabItem {
                Label("Log", systemImage: "ladybug.fill")
            }
            .tag(MainTab.log)
            #endif
        }
        .onAppear {
            AppLog.info("app", "Marauders launched")
        }
        // The feed is the first tab, so the saved session is restored here instead of waiting for
        // the viewer to open Map, Upload or Profile.
        .task {
            await authViewModel.restoreSession()
            // A saved session that did not come back (expired or revoked) ended without a sign-out, so the iPhone stops
            // sending that account's location while the app is closed.
            if !authViewModel.isSignedIn { friendLocationsViewModel.reset(signedOut: true) }
        }
        // Whether the viewer shares their location decides whether the app sends it while in use. It is asked again each
        // time the app comes to the foreground: the viewer may have changed it on another device, or the last ask failed.
        .task(id: authViewModel.isSignedIn && scenePhase == .active) {
            guard authViewModel.isSignedIn, scenePhase == .active else { return }
            await friendLocationsViewModel.refresh()
        }
        // A viewer who shares sends their location when the app comes to the foreground, then every few minutes while
        // it stays there. While it is closed, BackgroundLocationMonitor sends it when the iPhone moves.
        .task(id: scenePhase == .active && friendLocationsViewModel.sharing == true) {
            guard scenePhase == .active, friendLocationsViewModel.sharing == true else { return }
            while !Task.isCancelled {
                friendLocationsViewModel.reportLocationIfDue()
                try? await Task.sleep(for: .seconds(ForegroundLocationReporter.interval))
            }
        }
        .onChange(of: authViewModel.isSignedIn) { _, signedIn in
            if signedIn { showingSignIn = false }
            // The profile is dropped on sign-out only; after a sign-in the Profile tab may already be loading the
            // new viewer's.
            if !signedIn { profileViewModel.resetForSessionChange() }
            feedViewModel.resetForSessionChange()
            // What the previous viewer liked and followed is not what the reloaded feed says about the new one.
            clipLikesViewModel.reset()
            followsViewModel.reset()
            friendLocationsViewModel.reset(signedOut: !signedIn)
            Task { await feedViewModel.loadIfNeeded() }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: { signInDismissalID += 1 }) {
            SignInSheet(authViewModel: authViewModel, onClose: { showingSignIn = false })
        }
        .sheet(item: $router.publicProfileRoute) { route in
            PublicProfileView(
                viewModel: makePublicProfileViewModel(route.handle),
                authViewModel: authViewModel,
                onClose: { router.publicProfileRoute = nil }
            )
        }
    }
}

#Preview {
    let container = AppDependencyContainer()
    ContentView(
        router: container.router,
        coordinator: container.coordinator,
        feedViewModel: container.feedViewModel,
        uploadViewModel: container.uploadViewModel,
        authViewModel: container.authViewModel,
        profileViewModel: container.profileViewModel,
        reportUserLocation: container.reportUserLocation,
        makePublicProfileViewModel: { container.makePublicProfileViewModel(handle: $0) },
        makeCommentsViewModel: { container.makeCommentsViewModel(videoID: $0) },
        clipLikesViewModel: container.clipLikesViewModel,
        followsViewModel: container.followsViewModel,
        friendLocationsViewModel: container.friendLocationsViewModel
    )
}
