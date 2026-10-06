//
//  ContentView.swift
//  Marauders
//

import SwiftUI

struct ContentView: View {
    @State private var feedStore = FeedStore()

    var body: some View {
        TabView {
            VideoFeedView(store: feedStore)
                .tabItem {
                    Label("ฟีด", systemImage: "play.rectangle.fill")
                }

            UploadVideoView {
                await feedStore.reload()
            }
            .tabItem {
                Label("อัปโหลด", systemImage: "plus.circle.fill")
            }
        }
    }
}

#Preview {
    ContentView()
}
