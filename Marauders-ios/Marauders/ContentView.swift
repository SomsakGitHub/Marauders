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
    @Bindable var feedStore: FeedStore

    @State private var selectedTab: MainTab = .feed

    var body: some View {
        TabView(selection: $selectedTab) {
            VideoFeedView(store: feedStore)
                .tabItem {
                    Label("ฟีด", systemImage: "play.rectangle.fill")
                }
                .tag(MainTab.feed)

            UploadVideoView {
                await feedStore.reload()
                selectedTab = .feed
            }
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
    ContentView(feedStore: FeedStore())
}
