//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var viewModel: VideoFeedViewModel
    /// True while the Feed tab is the visible tab. Playback resumes only then,
    /// so a Map/Upload visit (or a system permission alert) never starts
    /// background audio/video.
    var isFeedTabSelected: Bool
    var isSignedIn: Bool
    var onSignIn: () -> Void = {}
    var signInDismissalID = 0
    /// Opens the public profile for a tapped author handle.
    var onOpenProfile: (String) -> Void = { _ in }

    @State private var isWaitingForSignIn = false
    @State private var isChoosingAudio = false
    @State private var resumeAfterAudioChoice = false
    private struct AudioRoute: Identifiable {
        let clip: FeedVideo
        /// The language to start dubbing in as soon as the player opens.
        let requestDubbingTarget: ListeningLanguage
        var id: UUID { clip.id }
    }
    @State private var audioRoute: AudioRoute?
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
                    ContentUnavailableView("No clips to show yet", systemImage: "play.rectangle",
                        description: Text("Check back later for new clips."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
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
        .fullScreenCover(item: $audioRoute, onDismiss: {
            if isFeedTabSelected, scenePhase == .active { applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex) }
        }) { route in
            if isSignedIn {
                ClipPlayerView(clip: route.clip, onClose: { audioRoute = nil }, requestDubbingTarget: route.requestDubbingTarget)
            }
        }
        .onChange(of: signInDismissalID) { _, _ in
            guard isWaitingForSignIn else { return }
            isWaitingForSignIn = false
            isChoosingAudio = false
            if isSignedIn {
                // The session change empties and reloads the feed, so the clip the guest was choosing audio for
                // is no longer under the pager. Never reopen it.
                resumeAfterAudioChoice = false
                guard isFeedTabSelected, scenePhase == .active else { return }
                applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
            } else {
                resumeAfterAudioChoiceIfNeeded()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.root")
        .task {
            await viewModel.loadIfNeeded()
            syncPageIndex()
            applyFocusRequestIfNeeded()
            warmInitialVideos()
            if isFeedTabSelected {
                applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
            }
        }
        .task(id: playerEngine.phase == .playing) {
            guard playerEngine.phase == .playing, isFeedTabSelected else { return }
            viewModel.prepareStartupCache(currentIndex: currentPageIndex)
        }
        .onChange(of: viewModel.videos) { _, _ in
            syncPageIndex()
            applyFocusRequestIfNeeded()
            guard isFeedTabSelected else { return }
            applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
        }
        .onChange(of: viewModel.focusVideoID) { _, _ in
            applyFocusRequestIfNeeded()
            guard isFeedTabSelected else { return }
            applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
        }
        .onChange(of: isSignedIn) { _, signedIn in
            if !signedIn { audioRoute = nil }
        }
        .onChange(of: isFeedTabSelected) { _, isSelected in
            if isSelected {
                applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
            } else {
                playerEngine.pause()
            }
        }
        .onDisappear {
            playerEngine.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard isFeedTabSelected else { return }
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
                    streamURLs: videos.map(\.streamURL),
                    currentPageIndex: $currentPageIndex,
                    engine: playerEngine,
                    onPageSettled: { index in
                        applyPlayback(for: viewModel.videos, pageIndex: index)
                        Task { await viewModel.loadMoreIfNearEnd(currentIndex: index) }
                    },
                    onTap: {
                        playerEngine.togglePlayPause()
                    }
                )
                .ignoresSafeArea()

                FeedPlaybackChrome(engine: playerEngine)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if let video = currentVideo {
                    FeedClipCaptionOverlay(clip: video)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    FeedClipActionRail(clip: video, onChooseAIAudio: { target in
                        guard isSignedIn else { isWaitingForSignIn = true; onSignIn(); return }
                        playerEngine.pause()
                        audioRoute = AudioRoute(clip: video, requestDubbingTarget: target)
                    }, onAuthorTap: onOpenProfile, canChooseAudio: isSignedIn,
                        onRequireSignIn: { isWaitingForSignIn = true; onSignIn() },
                        onAudioSelectionChanged: { open in
                            if open {
                                resumeAfterAudioChoice = playerEngine.phase == .playing
                                isChoosingAudio = true
                                playerEngine.pause()
                            } else {
                                isChoosingAudio = false
                                resumeAfterAudioChoiceIfNeeded()
                            }
                        })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                playbackOverlay
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var playbackOverlay: some View {        switch playerEngine.phase {
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

    private var currentVideo: FeedVideo? {
        guard viewModel.videos.indices.contains(currentPageIndex) else { return nil }
        return viewModel.videos[currentPageIndex]
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

    private func resumeAfterAudioChoiceIfNeeded() {
        guard resumeAfterAudioChoice, audioRoute == nil, !isWaitingForSignIn,
              isFeedTabSelected, scenePhase == .active else { return }
        resumeAfterAudioChoice = false
        applyPlayback(for: viewModel.videos, pageIndex: currentPageIndex)
    }

    private func applyPlayback(for videos: [FeedVideo], pageIndex: Int) {
        guard audioRoute == nil, !isChoosingAudio else { playerEngine.pause(); return }
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
                    streamURLs: videos.map(\.streamURL),
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
