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

    private let mediaPreparation = FeedMediaPreparationService(maxPreparedItems: 5)
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
        let protected = protectedMediaURLs()

        let service = mediaPreparation
        Task.detached(priority: .utility) {
            await service.prefetch(url: url, protected: protected)
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
        Task { await mediaPreparation.discardPreparedItem(for: url) }
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

        if autoplay {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }

            if let cached = await self.mediaPreparation.consumePreparedItem(for: url) {
                guard generation == self.loadGeneration else { return }
                slot.assign(
                    item: cached,
                    url: url,
                    autoplay: autoplay,
                    itemAlreadyBuffered: true,
                    generation: generation,
                    engine: self
                )
                return
            }

            do {
                guard let item = try await self.mediaPreparation.beginPlaybackItem(for: url) else {
                    if autoplay { self.failPlayback(message: "โหลดวิดีโอไม่สำเร็จ") }
                    return
                }
                guard generation == self.loadGeneration else { return }
                slot.assign(
                    item: item,
                    url: url,
                    autoplay: autoplay,
                    itemAlreadyBuffered: false,
                    generation: generation,
                    engine: self
                )
            } catch {
                guard generation == self.loadGeneration, autoplay else { return }
                self.failPlayback(message: error.localizedDescription)
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

    private func protectedMediaURLs() -> Set<URL> {
        Set([currentURL, hiddenSlot.loadedURL].compactMap { $0 })
    }

    private func scheduleBufferingIndicatorIfNeeded() {
        bufferingIndicatorTask?.cancel()
        bufferingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stallIndicatorDelayNs)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.phase == .buffering {
                self.showsBufferingIndicator = true
            }
        }
    }

    private func hideBufferingIndicator() {
        bufferingIndicatorTask?.cancel()
        bufferingIndicatorTask = nil
        showsBufferingIndicator = false
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
