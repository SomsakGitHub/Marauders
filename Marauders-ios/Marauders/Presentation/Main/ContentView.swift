//
//  ContentView.swift
//  Marauders
//

import SwiftUI

struct ContentView: View {
    @Bindable var router: AppRouter
    @Bindable var feedViewModel: VideoFeedViewModel
    @Bindable var uploadViewModel: UploadVideoViewModel

    var body: some View {
        TabView(selection: $router.selectedTab) {
            VideoFeedView(viewModel: feedViewModel)
                .tabItem {
                    Label("ฟีด", systemImage: "play.rectangle.fill")
                }
                .tag(MainTab.feed)

            UploadVideoView(viewModel: uploadViewModel)
                .tabItem {
                    Label("อัปโหลด", systemImage: "plus.circle.fill")
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
    }
}

#Preview {
    let container = AppDependencyContainer()
    ContentView(
        router: container.router,
        feedViewModel: container.feedViewModel,
        uploadViewModel: container.uploadViewModel
    )
}
