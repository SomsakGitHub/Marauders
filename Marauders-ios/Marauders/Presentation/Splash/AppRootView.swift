//
//  AppRootView.swift
//  Marauders
//

import SwiftUI

struct AppRootView: View {
    @State private var container = AppDependencyContainer()
    @State private var isShowingSplash = true
    @Environment(\.scenePhase) private var scenePhase

    private static let minimumSplashDurationNs: UInt64 = 650_000_000

    var body: some View {
        ZStack {
            ContentView(
                router: container.router,
                coordinator: container.coordinator,
                feedViewModel: container.feedViewModel,
                uploadViewModel: container.uploadViewModel,
                authViewModel: container.authViewModel,
                profileViewModel: container.profileViewModel,
                reportUserLocation: container.reportUserLocation,
                profileNavigation: container.profileNavigation,
                makeCommentsViewModel: { container.makeCommentsViewModel(videoID: $0) },
                clipLikesViewModel: container.clipLikesViewModel,
                followsViewModel: container.followsViewModel,
                friendLocationsViewModel: container.friendLocationsViewModel,
                languageModelsViewModel: container.languageModelsViewModel,
                accountDeletionViewModel: container.accountDeletionViewModel
            )
            .opacity(isShowingSplash ? 0 : 1)

            if isShowingSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .environment(\.dubbingViewModelFactory, DubbingViewModelFactory(make: { container.makeDubbingViewModel() }))
        .environment(\.listeningLanguageAvailability, container.listeningLanguageAvailability)
        .environment(\.listeningLanguageStore, container.listeningLanguageStore)
        .environment(\.listeningLanguagePicker, container.listeningLanguagePicker)
        .environment(\.videoThumbnailLoader, container.videoThumbnailLoader)
        .animation(AppRuntimeConfiguration.isUITesting ? nil : .easeOut(duration: 0.32), value: isShowingSplash)
        .task {
            await presentSplash()
        }
        .task {
            // Once, for the container this view keeps; the containers SwiftUI builds and drops connect nothing.
            await container.connectUploaderRejections()
        }
        .task {
            await container.uploadViewModel.observeUploads()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.uploadViewModel.setAppActive(phase == .active)
        }
        .onChange(of: container.authViewModel.isSignedIn, initial: true) { _, isSignedIn in
            container.uploadViewModel.setSignedIn(isSignedIn)
        }
        .onAppear {
            VideoPlaybackConfigurator.activateAudioSessionIfNeeded()
        }
    }

    private func presentSplash() async {
        await container.feedViewModel.awaitInitialLoad()

        if AppRuntimeConfiguration.isUITesting || container.feedViewModel.restoredStartupCache {
            isShowingSplash = false
            return
        }

        try? await Task.sleep(nanoseconds: Self.minimumSplashDurationNs)
        isShowingSplash = false
    }
}

#Preview {
    AppRootView()
}
