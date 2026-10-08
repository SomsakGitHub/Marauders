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
    /// Shown only after buffering lasts longer than a brief threshold (TikTok-style).
    private(set) var showsBufferingIndicator = false

    let playerLayer = AVPlayerLayer()

    private var player = AVPlayer()
    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var pausedByUser = false

    private var assetsByURL: [URL: AVURLAsset] = [:]
    private var preparedItems: [URL: AVPlayerItem] = [:]
    private var preparingURLs: Set<URL> = []
    private var bufferingIndicatorTask: Task<Void, Never>?

    private static let stallIndicatorDelayNs: UInt64 = 380_000_000
    private static let maxPreparedItems = 5

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

        clearObservers()

        if let item = takePreparedItem(for: url) {
            attach(item: item, url: url, generation: generation, itemAlreadyBuffered: true)
            return
        }

        phase = .buffering
        scheduleBufferingIndicatorIfNeeded()

        Task { [weak self] in
            guard let self else { return }
            let asset = await self.asset(for: url)
            do {
                let playable = try await asset.load(.isPlayable)
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    guard playable else {
                        self.failPlayback(message: "โหลดวิดีโอไม่สำเร็จ")
                        return
                    }
                    let item = self.makePlayerItem(asset: asset)
                    self.attach(item: item, url: url, generation: generation, itemAlreadyBuffered: false)
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    let message = error.localizedDescription
                    self.failPlayback(message: message)
                    AppLog.error("player", "asset load failed: \(message)")
                }
            }
        }
    }

    func prefetch(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        guard preparedItems[url] == nil, !preparingURLs.contains(url) else { return }

        preparingURLs.insert(url)
        trimCaches(keeping: url)

        Task { [weak self] in
            guard let self else { return }
            let asset = await self.asset(for: url)
            guard let ready = await self.prepareItem(asset: asset, url: url) else {
                await MainActor.run {
                    self.preparingURLs.remove(url)
                }
                return
            }
            await MainActor.run {
                self.preparingURLs.remove(url)
                guard self.preparedItems[url] == nil else { return }
                self.preparedItems[url] = ready
                self.trimCaches(keeping: url)
                AppLog.debug("player", "prepared item host=\(url.host ?? "?")")
            }
        }
    }

    func warmURLs(_ urls: [URL]) {
        for url in urls {
            prefetch(url: url)
        }
    }

    func pause(byUser: Bool = false) {
        player.pause()
        if byUser {
            pausedByUser = true
            phase = .paused
            hideBufferingIndicator()
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
        preparedItems.removeValue(forKey: url)
        currentURL = nil
        play(url: url)
    }

    private func attach(
        item: AVPlayerItem,
        url: URL,
        generation: Int,
        itemAlreadyBuffered: Bool
    ) {
        player.automaticallyWaitsToMinimizeStalling = !itemAlreadyBuffered

        if itemAlreadyBuffered, item.status == .readyToPlay {
            phase = .playing
            hideBufferingIndicator()
        } else {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }

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
                    self.failPlayback(message: message)
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
        AppLog.debug("player", "configured host=\(url.host ?? "?") buffered=\(itemAlreadyBuffered)")
    }

    private func takePreparedItem(for url: URL) -> AVPlayerItem? {
        guard let item = preparedItems.removeValue(forKey: url) else { return nil }
        return item
    }

    private func asset(for url: URL) async -> AVURLAsset {
        if let existing = assetsByURL[url] {
            return existing
        }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        assetsByURL[url] = asset
        return asset
    }

    private func makePlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 6
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func prepareItem(asset: AVURLAsset, url: URL) async -> AVPlayerItem? {
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return nil }
        } catch {
            return nil
        }

        let item = makePlayerItem(asset: asset)
        let ready = await waitUntilReadyToPlay(item)
        return ready ? item : nil
    }

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async -> Bool {
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }

        return await withCheckedContinuation { continuation in
            final class ResumeGuard: @unchecked Sendable {
                var resumed = false
                func resumeOnce(_ value: Bool) -> Bool {
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }
            let guardBox = ResumeGuard()
            var observation: NSKeyValueObservation?
            observation = item.observe(\.status, options: [.new]) { item, _ in
                switch item.status {
                case .readyToPlay:
                    if guardBox.resumeOnce(true) {
                        observation?.invalidate()
                        continuation.resume(returning: true)
                    }
                case .failed:
                    if guardBox.resumeOnce(false) {
                        observation?.invalidate()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
        }
    }

    private func updatePhaseFromPlayer() {
        guard player.currentItem?.status != .failed else { return }

        switch player.timeControlStatus {
        case .playing:
            phase = .playing
            hideBufferingIndicator()
        case .waitingToPlayAtSpecifiedRate:
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        case .paused:
            if pausedByUser {
                phase = .paused
                hideBufferingIndicator()
            } else if player.currentItem?.status == .readyToPlay {
                phase = .buffering
                scheduleBufferingIndicatorIfNeeded()
            }
        @unknown default:
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }
    }

    private func failPlayback(message: String) {
        phase = .failed(message)
        hideBufferingIndicator()
    }

    private func scheduleBufferingIndicatorIfNeeded() {
        bufferingIndicatorTask?.cancel()
        bufferingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stallIndicatorDelayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.phase == .buffering {
                    self.showsBufferingIndicator = true
                }
            }
        }
    }

    private func hideBufferingIndicator() {
        bufferingIndicatorTask?.cancel()
        bufferingIndicatorTask = nil
        showsBufferingIndicator = false
    }

    private func trimCaches(keeping url: URL) {
        let protected = Set(
            [url, currentURL].compactMap { $0 }
        )

        if assetsByURL.count > Self.maxPreparedItems + 2 {
            for key in assetsByURL.keys where !protected.contains(key) && preparedItems[key] == nil {
                assetsByURL.removeValue(forKey: key)
                if assetsByURL.count <= Self.maxPreparedItems + 2 { break }
            }
        }

        if preparedItems.count > Self.maxPreparedItems {
            for key in preparedItems.keys where !protected.contains(key) {
                preparedItems.removeValue(forKey: key)
                if preparedItems.count <= Self.maxPreparedItems { break }
            }
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
