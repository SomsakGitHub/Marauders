//
//  ContentView.swift
//  Marauders
//

import SwiftUI

struct ContentView: View {
    @Bindable var router: AppRouter
    let coordinator: AppCoordinator
    @Bindable var feedViewModel: VideoFeedViewModel
    @Bindable var uploadViewModel: UploadVideoViewModel
    @Bindable var authViewModel: AuthViewModel
    @Bindable var profileViewModel: ProfileViewModel
    let reportUserLocation: ReportUserLocationUseCase
    let makePublicProfileViewModel: (String) -> PublicProfileViewModel

    var body: some View {
        TabView(selection: $router.selectedTab) {
            VideoFeedView(
                viewModel: feedViewModel,
                isFeedTabSelected: router.selectedTab == .feed,
                onOpenProfile: { router.openPublicProfile(handle: $0) }
            )
                .tabItem {
                    Label("Feed", systemImage: "play.rectangle.fill")
                }
                .tag(MainTab.feed)

            MapTabView(
                authViewModel: authViewModel,
                feedViewModel: feedViewModel,
                reportUserLocation: reportUserLocation,
                onOpenClipInFeed: { videoID in
                    await coordinator.openClipInFeed(videoID: videoID)
                }
            )
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(MainTab.map)

            ProfileTabView(
                authViewModel: authViewModel,
                profileViewModel: profileViewModel
            )
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                .tag(MainTab.profile)

            UploadTabView(
                authViewModel: authViewModel,
                uploadViewModel: uploadViewModel
            )
                .tabItem {
                    Label("Upload", systemImage: "plus.circle.fill")
                }
                .tag(MainTab.upload)

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
        .onChange(of: authViewModel.isSignedIn) { _, _ in
            feedViewModel.resetForSessionChange()
            Task { await feedViewModel.loadIfNeeded() }
        }
        .sheet(item: $router.publicProfileRoute) { route in
            PublicProfileView(
                viewModel: makePublicProfileViewModel(route.handle),
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
        makePublicProfileViewModel: { container.makePublicProfileViewModel(handle: $0) }
    )
}
