//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Bindable var store: FeedStore

    @State private var currentVideoID: FeedVideo.ID?

    var body: some View {
        Group {
            if store.videos.isEmpty {
                switch store.loadState {
                case .idle, .loading:
                    loadingView
                case .failed(let message):
                    errorView(message: message)
                case .loaded:
                    feedScroll(videos: store.videos)
                }
            } else {
                feedScroll(videos: store.videos)
                    .overlay {
                        if store.loadState == .loading {
                            ProgressView()
                                .tint(.white)
                                .padding(12)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                    }
            }
        }
        .task {
            await store.loadIfNeeded()
            syncCurrentVideoID()
        }
        .onChange(of: store.videos) { _, _ in
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
                    Task { await store.reload() }
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
        let videos = store.videos
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

/// Preview-only feed without API.
struct VideoFeedPreviewView: View {
    @State private var currentVideoID: FeedVideo.ID?
    let videos: [FeedVideo]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoFeedPageView(video: video, isActive: currentVideoID == video.id)
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
        .onAppear {
            currentVideoID = videos.first?.id
        }
    }
}

#Preview {
    VideoFeedPreviewView(videos: FeedSampleData.videos)
}
