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
                feedViewModel: container.feedViewModel,
                uploadViewModel: container.uploadViewModel
            )
            .opacity(isShowingSplash ? 0 : 1)

            if isShowingSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.32), value: isShowingSplash)
        .task {
            await presentSplash()
        }
        .onAppear {
            VideoPlaybackConfigurator.activateAudioSessionIfNeeded()
        }
    }

    private func presentSplash() async {
        async let feedLoad: Void = container.coordinator.loadFeedIfNeeded()
        async let minimumDelay: Void = {
            try? await Task.sleep(nanoseconds: Self.minimumSplashDurationNs)
        }()

        _ = await (feedLoad, minimumDelay)

        isShowingSplash = false
    }
}

#Preview {
    AppRootView()
}
