//
//  FeedPlayerEngine.swift
//  Marauders
//

import AVFoundation
import Observation

enum FeedPlayerPhase: Equatable, Sendable {
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
    private(set) var showsBufferingIndicator = false
    private(set) var visibleSlotIsA = true

    let layerA = AVPlayerLayer()
    let layerB = AVPlayerLayer()

    /// Visible slot layer (for single-layer call sites).
    var playerLayer: AVPlayerLayer {
        visibleSlotIsA ? layerA : layerB
    }

    private let slotA: PlayerSlot
    private let slotB: PlayerSlot

    private var currentURL: URL?
    private var loadGeneration = 0
    private var pausedByUser = false

    private var assetsByURL: [URL: AVURLAsset] = [:]
    private var preparedItems: [URL: AVPlayerItem] = [:]
    private var preparingURLs: Set<URL> = []
    private var bufferingIndicatorTask: Task<Void, Never>?

    private static let stallIndicatorDelayNs: UInt64 = 380_000_000
    private static let maxPreparedItems = 5

    init() {
        layerA.videoGravity = .resizeAspectFill
        layerB.videoGravity = .resizeAspectFill
        slotA = PlayerSlot(layer: layerA)
        slotB = PlayerSlot(layer: layerB)
        slotA.player.automaticallyWaitsToMinimizeStalling = true
        slotB.player.automaticallyWaitsToMinimizeStalling = true
    }

    func togglePlayPause() {
        let player = visibleSlot.player
        switch player.timeControlStatus {
        case .playing:
            pause(byUser: true)
        default:
            pausedByUser = false
            player.play()
            updatePhaseFromVisiblePlayer()
        }
    }

    /// Settles on a page after paging — swaps to preloaded hidden slot when possible.
    func settle(on url: URL, prefetchNeighbors: [URL]) {
        guard validateHTTPS(url) else { return }
        pausedByUser = false

        if currentURL == url, visibleSlot.player.currentItem != nil {
            visibleSlot.player.play()
            updatePhaseFromVisiblePlayer()
            preloadHidden(urls: prefetchNeighbors)
            return
        }

        if swapToHiddenIfReady(url: url) {
            currentURL = url
            updatePhaseFromVisiblePlayer()
            preloadHidden(urls: prefetchNeighbors)
            AppLog.debug("player", "swap host=\(url.host ?? "?")")
            return
        }

        currentURL = url
        playOnVisible(url: url)
        preloadHidden(urls: prefetchNeighbors)
    }

    func play(url: URL) {
        settle(on: url, prefetchNeighbors: [])
    }

    func prefetch(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        guard preparedItems[url] == nil, !preparingURLs.contains(url) else { return }

        preparingURLs.insert(url)
        trimCaches(keeping: url)

        Task { [weak self] in
            guard let self else { return }
            let asset = await self.asset(for: url)
            guard let ready = await self.prepareItem(asset: asset) else {
                await MainActor.run { self.preparingURLs.remove(url) }
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
        visibleSlot.player.pause()
        hiddenSlot.player.pause()
        if byUser {
            pausedByUser = true
            phase = .paused
            hideBufferingIndicator()
        } else {
            updatePhaseFromVisiblePlayer()
        }
    }

    func resume() {
        visibleSlot.player.play()
        updatePhaseFromVisiblePlayer()
    }

    func retry() {
        guard let url = currentURL else { return }
        preparedItems.removeValue(forKey: url)
        currentURL = nil
        playOnVisible(url: url)
    }

    // MARK: - Slots

    private var visibleSlot: PlayerSlot {
        visibleSlotIsA ? slotA : slotB
    }

    private var hiddenSlot: PlayerSlot {
        visibleSlotIsA ? slotB : slotA
    }

    private func swapToHiddenIfReady(url: URL) -> Bool {
        let hidden = hiddenSlot
        guard hidden.loadedURL == url,
              hidden.player.currentItem?.status == .readyToPlay
        else {
            return false
        }

        visibleSlot.player.pause()
        hidden.player.playImmediately(atRate: 1.0)
        visibleSlotIsA.toggle()
        phase = .playing
        hideBufferingIndicator()
        return true
    }

    private func preloadHidden(urls: [URL]) {
        guard let next = urls.first(where: { $0 != currentURL && $0 != hiddenSlot.loadedURL }) else {
            return
        }
        load(into: hiddenSlot, url: next, autoplay: false, generation: loadGeneration)
    }

    private func playOnVisible(url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        load(into: visibleSlot, url: url, autoplay: true, generation: generation)
    }

    private func load(
        into slot: PlayerSlot,
        url: URL,
        autoplay: Bool,
        generation: Int
    ) {
        slot.clearObservers()

        if let item = takePreparedItem(for: url) {
            slot.assign(
                item: item,
                url: url,
                autoplay: autoplay,
                itemAlreadyBuffered: true,
                generation: generation,
                engine: self
            )
            return
        }

        if autoplay {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }
            let asset = await self.asset(for: url)
            do {
                let playable = try await asset.load(.isPlayable)
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    guard playable else {
                        if autoplay { self.failPlayback(message: "โหลดวิดีโอไม่สำเร็จ") }
                        return
                    }
                    let item = self.makePlayerItem(asset: asset)
                    slot.assign(
                        item: item,
                        url: url,
                        autoplay: autoplay,
                        itemAlreadyBuffered: false,
                        generation: generation,
                        engine: self
                    )
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration, autoplay else { return }
                    self.failPlayback(message: error.localizedDescription)
                }
            }
        }
    }

    private func validateHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            phase = .failed("URL ไม่ปลอดภัย")
            return false
        }
        return true
    }

    fileprivate func updatePhaseFromVisiblePlayer() {
        let player = visibleSlot.player
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

    private func takePreparedItem(for url: URL) -> AVPlayerItem? {
        return preparedItems.removeValue(forKey: url)
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

    private func prepareItem(asset: AVURLAsset) async -> AVPlayerItem? {
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
        let protected = Set([url, currentURL, hiddenSlot.loadedURL].compactMap { $0 })

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
}

// MARK: - Player slot

@MainActor
private final class PlayerSlot {
    let player: AVPlayer
    let layer: AVPlayerLayer
    private(set) var loadedURL: URL?

    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(layer: AVPlayerLayer) {
        self.layer = layer
        player = AVPlayer()
        layer.player = player
    }

    func assign(
        item: AVPlayerItem,
        url: URL,
        autoplay: Bool,
        itemAlreadyBuffered: Bool,
        generation: Int,
        engine: FeedPlayerEngine
    ) {
        loadedURL = url
        player.automaticallyWaitsToMinimizeStalling = !itemAlreadyBuffered

        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                guard autoplay, generation == engine.loadGenerationForObservers else { return }
                switch item.status {
                case .readyToPlay:
                    AppLog.info("player", "ready host=\(url.host ?? "?")")
                    engine.updatePhaseFromVisiblePlayer()
                case .failed:
                    let message = item.error?.localizedDescription ?? "เล่นไม่ได้"
                    engine.failPlaybackFromSlot(message: message)
                default:
                    break
                }
            }
        }

        if autoplay {
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
                Task { @MainActor in
                    guard generation == engine.loadGenerationForObservers else { return }
                    engine.updatePhaseFromVisiblePlayer()
                }
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

        if autoplay {
            if itemAlreadyBuffered, item.status == .readyToPlay {
                engine.markPlayingFromSlot()
                player.playImmediately(atRate: 1.0)
            } else {
                player.play()
            }
        } else {
            player.seek(to: .zero)
            player.pause()
        }
    }

    func clearObservers() {
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

extension FeedPlayerEngine {
    fileprivate var loadGenerationForObservers: Int {
        loadGeneration
    }

    fileprivate func failPlaybackFromSlot(message: String) {
        failPlayback(message: message)
    }

    fileprivate func markPlayingFromSlot() {
        phase = .playing
        hideBufferingIndicator()
    }
}
