//
//  ContentView.swift
//  Marauders
//

import SwiftUI

private enum MainTab: Hashable {
    case feed
    case upload
    case log
}

struct ContentView: View {
    @Bindable var feedViewModel: VideoFeedViewModel
    @Bindable var uploadViewModel: UploadVideoViewModel

    @State private var selectedTab: MainTab = .feed

    var body: some View {
        TabView(selection: $selectedTab) {
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
            uploadViewModel.onUploaded = {
                await feedViewModel.reload()
                selectedTab = .feed
            }
        }
    }
}

#Preview {
    let container = AppDependencyContainer()
    ContentView(
        feedViewModel: container.feedViewModel,
        uploadViewModel: container.uploadViewModel
    )
}
