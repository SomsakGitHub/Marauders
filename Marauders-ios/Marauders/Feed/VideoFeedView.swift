//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @State private var currentVideoID: FeedVideo.ID?

    private let store: FeedStore?
    private let previewVideos: [FeedVideo]?

    init(store: FeedStore) {
        self.store = store
        self.previewVideos = nil
    }

    init(previewVideos: [FeedVideo]) {
        self.store = nil
        self.previewVideos = previewVideos
    }

    private var activeVideos: [FeedVideo] {
        previewVideos ?? store?.videos ?? []
    }

    var body: some View {
        Group {
            if let previewVideos {
                feedScroll(videos: previewVideos)
            } else if let store {
                switch store.loadState {
                case .idle, .loading:
                    loadingView
                case .failed(let message):
                    errorView(message: message)
                case .loaded:
                    feedScroll(videos: store.videos)
                }
            }
        }
        .task {
            if let store, previewVideos == nil {
                await store.loadIfNeeded()
                syncCurrentVideoID()
            }
        }
        .onChange(of: store?.videos ?? []) { _, _ in
            syncCurrentVideoID()
        }
    }

    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .tint(.white)
        }
    }

    private func errorView(message: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 24)
                Button("ลองอีกครั้ง") {
                    Task {
                        if let store {
                            await store.reload()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func feedScroll(videos: [FeedVideo]) -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoFeedPageView(
                            video: video,
                            isActive: currentVideoID == video.id
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(video.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentVideoID)
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    private func syncCurrentVideoID() {
        let videos = activeVideos
        guard !videos.isEmpty else {
            currentVideoID = nil
            return
        }
        if let currentVideoID, videos.contains(where: { $0.id == currentVideoID }) {
            return
        }
        currentVideoID = videos.first?.id
    }
}

#Preview {
    VideoFeedView(previewVideos: FeedSampleData.videos)
}
