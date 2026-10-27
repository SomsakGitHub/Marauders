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
                onSignIn: { showingSignIn = true },
                onOpenClipInFeed: { videoID in
                    await coordinator.openClipInFeed(videoID: videoID)
                },
                onOpenProfile: { router.openPublicProfile(handle: $0) }
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

            SettingsView(languageModels: languageModelsViewModel)
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
        .task { await authViewModel.restoreSession() }
        .onChange(of: authViewModel.isSignedIn) { _, signedIn in
            if signedIn { showingSignIn = false }
            feedViewModel.resetForSessionChange()
            Task { await feedViewModel.loadIfNeeded() }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: { signInDismissalID += 1 }) {
            SignInWithAppleGateView(
                authViewModel: authViewModel,
                navigationTitle: "Sign in",
                systemImage: "person.crop.circle.fill",
                title: "Welcome to Marauders",
                subtitle: "Sign in with Apple to continue.",
                accessibilityIdentifier: "auth.signIn"
            )
            .overlay(alignment: .topTrailing) {
                Button { showingSignIn = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).padding()
                }
                .accessibilityLabel("Close sign in")
                .accessibilityIdentifier("auth.closeSignIn")
            }
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
