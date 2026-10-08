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

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func play(url: URL) {
        guard url.scheme?.lowercased() == "https" else {
            phase = .failed("URL ไม่ปลอดภัย")
            return
        }

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

        let asset = AVURLAsset(url: url)
        let keys = ["playable"]
        asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.loadGeneration else { return }

                for key in keys {
                    var error: NSError?
                    let status = asset.statusOfValue(forKey: key, error: &error)
                    if status != .loaded {
                        let message = error?.localizedDescription ?? "โหลดวิดีโอไม่สำเร็จ"
                        self.phase = .failed(message)
                        AppLog.error("player", "asset load failed: \(message)")
                        return
                    }
                }

                self.startItem(asset: asset, url: url, generation: generation)
            }
        }
    }

    func prefetch(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable"]) { }
        AppLog.debug("player", "prefetch host=\(url.host ?? "?")")
    }

    func pause() {
        player.pause()
        if case .playing = phase {
            phase = .buffering
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
        item.preferredForwardBufferDuration = 5

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
            if player.currentItem?.status == .readyToPlay {
                phase = .buffering
            }
        @unknown default:
            phase = .buffering
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
