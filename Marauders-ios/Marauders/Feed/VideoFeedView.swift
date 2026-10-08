//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FeedStore

    @State private var currentVideoID: FeedVideo.ID?
    @State private var playerEngine = FeedPlayerEngine()

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
            applyPlayback(for: store.videos)
        }
        .onChange(of: store.videos) { _, _ in
            syncCurrentVideoID()
            applyPlayback(for: store.videos)
        }
        .onChange(of: currentVideoID) { _, _ in
            applyPlayback(for: store.videos)
        }
        .onDisappear {
            playerEngine.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                applyPlayback(for: store.videos)
            case .background:
                playerEngine.pause()
            case .inactive:
                playerEngine.pause()
            @unknown default:
                break
            }
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
            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(videos) { video in
                            VideoFeedPageView()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentVideoID)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        playerEngine.togglePlayPause()
                    }
                )

                FeedPlayerSurface(engine: playerEngine)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)

                FeedPlaybackChrome(engine: playerEngine)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                playbackOverlay
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    @ViewBuilder
    private var playbackOverlay: some View {
        switch playerEngine.phase {
        case .idle, .playing, .paused:
            EmptyView()
        case .buffering:
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
                .allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.title)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 32)
                Button("เล่นอีกครั้ง") {
                    playerEngine.retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
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

    private func applyPlayback(for videos: [FeedVideo]) {
        guard let currentVideoID,
              let index = videos.firstIndex(where: { $0.id == currentVideoID })
        else {
            playerEngine.pause()
            return
        }

        let current = videos[index]
        playerEngine.play(url: current.streamURL)

        if index > 0 {
            playerEngine.prefetch(url: videos[index - 1].streamURL)
        }
        if index + 1 < videos.count {
            playerEngine.prefetch(url: videos[index + 1].streamURL)
        }
    }
}

/// Preview-only feed without API.
struct VideoFeedPreviewView: View {
    @State private var currentVideoID: FeedVideo.ID?
    @State private var playerEngine = FeedPlayerEngine()
    let videos: [FeedVideo]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(videos) { video in
                            VideoFeedPageView()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentVideoID)

                FeedPlayerSurface(engine: playerEngine)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            currentVideoID = videos.first?.id
            if let first = videos.first {
                playerEngine.play(url: first.streamURL)
            }
        }
        .onChange(of: currentVideoID) { _, id in
            guard let id, let video = videos.first(where: { $0.id == id }) else { return }
            playerEngine.play(url: video.streamURL)
        }
    }
}

#Preview {
    VideoFeedPreviewView(videos: FeedSampleData.videos)
}
