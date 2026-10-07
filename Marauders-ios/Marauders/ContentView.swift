//
//  ContentView.swift
//  Marauders
//

import SwiftUI

private enum MainTab: Hashable {
    case feed
    case upload
}

struct ContentView: View {
    @State private var feedStore = FeedStore()
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
        }
    }
}

#Preview {
    ContentView()
}
