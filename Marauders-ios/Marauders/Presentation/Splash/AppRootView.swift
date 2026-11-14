//
//  AppRootView.swift
//  Marauders
//

import SwiftUI

struct AppRootView: View {
    @State private var container = AppDependencyContainer()
    @State private var isShowingSplash = true

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
                friendLocationsViewModel: container.friendLocationsViewModel
            )
            .opacity(isShowingSplash ? 0 : 1)

            if isShowingSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(AppRuntimeConfiguration.isUITesting ? nil : .easeOut(duration: 0.32), value: isShowingSplash)
        .task {
            await presentSplash()
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
