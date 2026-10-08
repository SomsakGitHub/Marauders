//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FeedStore

    @State private var currentPageIndex = 0
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
            syncPageIndex()
            warmInitialVideos()
            applyPlayback(for: store.videos, pageIndex: currentPageIndex)
        }
        .onChange(of: store.videos) { _, _ in
            syncPageIndex()
            applyPlayback(for: store.videos, pageIndex: currentPageIndex)
        }
        .onDisappear {
            playerEngine.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                applyPlayback(for: store.videos, pageIndex: currentPageIndex)
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
                VerticalPagingFeedScrollView(
                    pageCount: videos.count,
                    currentPageIndex: $currentPageIndex,
                    engine: playerEngine,
                    onPageSettled: { index in
                        applyPlayback(for: videos, pageIndex: index)
                    },
                    onTap: {
                        playerEngine.togglePlayPause()
                    }
                )

                FeedPlaybackChrome(engine: playerEngine)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)

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
            if playerEngine.showsBufferingIndicator {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
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

    private func syncPageIndex() {
        let count = store.videos.count
        guard count > 0 else {
            currentPageIndex = 0
            return
        }
        if currentPageIndex >= count {
            currentPageIndex = count - 1
        }
    }

    private func warmInitialVideos() {
        let urls = store.videos.prefix(3).map(\.streamURL)
        playerEngine.warmURLs(urls)
    }

    private func applyPlayback(for videos: [FeedVideo], pageIndex: Int) {
        guard !videos.isEmpty else {
            playerEngine.pause()
            return
        }
        let index = min(max(pageIndex, 0), videos.count - 1)
        let current = videos[index]

        var neighbors: [URL] = []
        if index + 1 < videos.count {
            neighbors.append(videos[index + 1].streamURL)
        }
        if index > 0 {
            neighbors.append(videos[index - 1].streamURL)
        }
        if index + 2 < videos.count {
            neighbors.append(videos[index + 2].streamURL)
        }
        playerEngine.warmURLs(neighbors)
        playerEngine.settle(on: current.streamURL, prefetchNeighbors: neighbors)
    }
}

/// Preview-only feed without API.
struct VideoFeedPreviewView: View {
    @State private var currentPageIndex = 0
    @State private var playerEngine = FeedPlayerEngine()
    let videos: [FeedVideo]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VerticalPagingFeedScrollView(
                    pageCount: videos.count,
                    currentPageIndex: $currentPageIndex,
                    engine: playerEngine,
                    onPageSettled: { index in
                        guard videos.indices.contains(index) else { return }
                        playerEngine.settle(on: videos[index].streamURL, prefetchNeighbors: [])
                    },
                    onTap: {
                        playerEngine.togglePlayPause()
                    }
                )
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            if let first = videos.first {
                playerEngine.play(url: first.streamURL)
            }
        }
    }
}

#Preview {
    VideoFeedPreviewView(videos: FeedSampleData.videos)
}
