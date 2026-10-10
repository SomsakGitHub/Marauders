//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var viewModel: VideoFeedViewModel

    @State private var currentPageIndex = 0
    @State private var playerEngine = FeedPlayerEngine()

    var body: some View {
        Group {
            if viewModel.videos.isEmpty {
                switch viewModel.loadState {
                case .idle, .loading:
                    loadingView
                case .failed(let message):
                    errorView(message: message)
                case .loaded:
                    feedScroll(videos: viewModel.videos)
                }
            } else {
                feedScroll(videos: viewModel.videos)
                    .overlay {
                        if viewModel.loadState == .loading {
                            ProgressView()
                                .tint(.white)
                                .padding(12)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                    }
            }
        }
        .accessibilityIdentifier("feed.root")
        .task {
            await viewModel.loadIfNeeded()
            syncPageIndex()
            applyFocusRequestIfNeeded()
            warmInitialVideos()
            applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
        }
        .onChange(of: viewModel.videos) { _, _ in
            syncPageIndex()
            applyFocusRequestIfNeeded()
            applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
        }
        .onChange(of: viewModel.focusVideoID) { _, _ in
            applyFocusRequestIfNeeded()
            applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
        }
        .onDisappear {
            playerEngine.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
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
        .accessibilityIdentifier("feed.loading")
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
                    .accessibilityIdentifier("feed.error.message")
                Button("Try Again") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("feed.retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("feed.error")
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
                Button("Play Again") {
                    playerEngine.retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func syncPageIndex() {
        let count = viewModel.videos.count
        guard count > 0 else {
            currentPageIndex = 0
            return
        }
        if currentPageIndex >= count {
            currentPageIndex = count - 1
        }
    }

    private func applyFocusRequestIfNeeded() {
        guard let videoID = viewModel.consumeFocusRequest() else { return }
        guard let index = viewModel.videos.firstIndex(where: { $0.id == videoID }) else { return }
        currentPageIndex = index
    }

    private func warmInitialVideos() {
        let urls = viewModel.videos.prefix(3).map(\.streamURL)
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
