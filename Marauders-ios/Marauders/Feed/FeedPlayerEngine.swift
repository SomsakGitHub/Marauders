//
//  FeedPlayerEngine.swift
//  Marauders
//

import AVFoundation
import Observation

enum FeedPlayerPhase: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case failed(String)
}

@MainActor
@Observable
final class FeedPlayerEngine {
    private(set) var phase: FeedPlayerPhase = .idle

    let playerLayer = AVPlayerLayer()

    private var player = AVPlayer()
    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var pausedByUser = false
    private var prefetchAssets: [URL: AVURLAsset] = [:]

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func togglePlayPause() {
        switch player.timeControlStatus {
        case .playing:
            pause(byUser: true)
        default:
            pausedByUser = false
            player.play()
            updatePhaseFromPlayer()
        }
    }

    func play(url: URL) {
        guard url.scheme?.lowercased() == "https" else {
            phase = .failed("URL ไม่ปลอดภัย")
            return
        }

        pausedByUser = false

        if currentURL == url, player.currentItem != nil {
            player.play()
            updatePhaseFromPlayer()
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        currentURL = url
        phase = .buffering

        clearObservers()

        if let cached = prefetchAssets[url] {
            startItem(asset: cached, url: url, generation: generation)
            return
        }

        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            do {
                let playable = try await asset.load(.isPlayable)
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    guard playable else {
                        self.phase = .failed("โหลดวิดีโอไม่สำเร็จ")
                        return
                    }
                    self.startItem(asset: asset, url: url, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    let message = error.localizedDescription
                    self.phase = .failed(message)
                    AppLog.error("player", "asset load failed: \(message)")
                }
            }
        }
    }

    func prefetch(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        guard prefetchAssets[url] == nil else { return }

        let asset = AVURLAsset(url: url)
        prefetchAssets[url] = asset
        trimPrefetchCache(keeping: url)

        Task {
            _ = try? await asset.load(.isPlayable)
            await MainActor.run {
                AppLog.debug("player", "prefetch ready host=\(url.host ?? "?")")
            }
        }
    }

    func pause(byUser: Bool = false) {
        player.pause()
        if byUser {
            pausedByUser = true
            phase = .paused
        } else {
            updatePhaseFromPlayer()
        }
    }

    func resume() {
        player.play()
        updatePhaseFromPlayer()
    }

    func retry() {
        guard let url = currentURL else { return }
        currentURL = nil
        play(url: url)
    }

    private func startItem(asset: AVURLAsset, url: URL, generation: Int) {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, generation == self.loadGeneration else { return }
                switch item.status {
                case .readyToPlay:
                    AppLog.info("player", "ready host=\(url.host ?? "?")")
                    self.updatePhaseFromPlayer()
                case .failed:
                    let nsError = item.error as NSError?
                    let message = item.error?.localizedDescription ?? "เล่นไม่ได้"
                    self.phase = .failed(message)
                    AppLog.error(
                        "player",
                        "failed host=\(url.host ?? "?") code=\(nsError?.code ?? 0) error=\(message)"
                    )
                default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, generation == self.loadGeneration else { return }
                self.updatePhaseFromPlayer()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        AppLog.debug("player", "configured host=\(url.host ?? "?")")
    }

    private func updatePhaseFromPlayer() {
        guard player.currentItem?.status != .failed else { return }

        switch player.timeControlStatus {
        case .playing:
            phase = .playing
        case .waitingToPlayAtSpecifiedRate:
            phase = .buffering
        case .paused:
            if pausedByUser {
                phase = .paused
            } else if player.currentItem?.status == .readyToPlay {
                phase = .buffering
            }
        @unknown default:
            phase = .buffering
        }
    }

    private func trimPrefetchCache(keeping url: URL) {
        let maxEntries = 4
        guard prefetchAssets.count > maxEntries else { return }
        for key in prefetchAssets.keys where key != url && key != currentURL {
            prefetchAssets.removeValue(forKey: key)
            if prefetchAssets.count <= maxEntries { break }
        }
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}
