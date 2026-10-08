//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FeedStore

    @State private var currentVideoID: FeedVideo.ID?
    @State private var playbackVideoID: FeedVideo.ID?
    @State private var scrollOffsetY: CGFloat = 0
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
            let initialWarm = store.videos.prefix(3).map(\.streamURL)
            playerEngine.warmURLs(initialWarm)
            applyPlayback(for: store.videos)
        }
        .onChange(of: store.videos) { _, _ in
            syncCurrentVideoID()
            applyPlayback(for: store.videos)
        }
        .onChange(of: currentVideoID) { _, newID in
            if let newID {
                playbackVideoID = newID
            }
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
            let pageHeight = geometry.size.height

            ZStack(alignment: .top) {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(videos) { video in
                            VideoFeedPageView()
                                .frame(width: geometry.size.width, height: pageHeight)
                                .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentVideoID)
                .scrollClipDisabled()
                .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                    scrollGeometry.contentOffset.y
                } action: { _, offsetY in
                    scrollOffsetY = offsetY
                    updatePlaybackWhileScrolling(
                        videos: videos,
                        offsetY: offsetY,
                        pageHeight: pageHeight
                    )
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        playerEngine.togglePlayPause()
                    }
                )

                if let playbackVideoID,
                   let index = videos.firstIndex(where: { $0.id == playbackVideoID }) {
                    FeedPlayerSurface(engine: playerEngine)
                        .frame(width: geometry.size.width, height: pageHeight)
                        .offset(y: CGFloat(index) * pageHeight - scrollOffsetY)
                        .allowsHitTesting(false)
                }

                FeedPlaybackChrome(engine: playerEngine)
                    .frame(width: geometry.size.width, height: pageHeight)
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

    private func syncCurrentVideoID() {
        let videos = store.videos
        guard !videos.isEmpty else {
            currentVideoID = nil
            playbackVideoID = nil
            return
        }
        if let currentVideoID, videos.contains(where: { $0.id == currentVideoID }) {
            if playbackVideoID == nil {
                playbackVideoID = currentVideoID
            }
            return
        }
        currentVideoID = videos.first?.id
        playbackVideoID = videos.first?.id
    }

    private func updatePlaybackWhileScrolling(
        videos: [FeedVideo],
        offsetY: CGFloat,
        pageHeight: CGFloat
    ) {
        guard pageHeight > 0, !videos.isEmpty else { return }

        let index = min(
            max(Int((offsetY + pageHeight * 0.5) / pageHeight), 0),
            videos.count - 1
        )
        let id = videos[index].id

        guard playbackVideoID != id else { return }
        playbackVideoID = id
        applyPlayback(for: videos, focusedID: id)
    }

    private func applyPlayback(for videos: [FeedVideo], focusedID: FeedVideo.ID? = nil) {
        let targetID = focusedID ?? playbackVideoID ?? currentVideoID
        guard let targetID,
              let index = videos.firstIndex(where: { $0.id == targetID })
        else {
            playerEngine.pause()
            return
        }

        let current = videos[index]
        playerEngine.play(url: current.streamURL)

        var neighbors: [URL] = []
        if index > 0 {
            neighbors.append(videos[index - 1].streamURL)
        }
        if index + 1 < videos.count {
            neighbors.append(videos[index + 1].streamURL)
        }
        if index + 2 < videos.count {
            neighbors.append(videos[index + 2].streamURL)
        }
        playerEngine.warmURLs(neighbors)
    }
}

/// Preview-only feed without API.
struct VideoFeedPreviewView: View {
    @State private var currentVideoID: FeedVideo.ID?
    @State private var scrollOffsetY: CGFloat = 0
    @State private var playerEngine = FeedPlayerEngine()
    let videos: [FeedVideo]

    var body: some View {
        GeometryReader { geometry in
            let pageHeight = geometry.size.height

            ZStack(alignment: .top) {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(videos) { video in
                            VideoFeedPageView()
                                .frame(width: geometry.size.width, height: pageHeight)
                                .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentVideoID)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    scrollOffsetY = y
                }

                if let currentVideoID,
                   let index = videos.firstIndex(where: { $0.id == currentVideoID }) {
                    FeedPlayerSurface(engine: playerEngine)
                        .frame(width: geometry.size.width, height: pageHeight)
                        .offset(y: CGFloat(index) * pageHeight - scrollOffsetY)
                        .allowsHitTesting(false)
                }
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
