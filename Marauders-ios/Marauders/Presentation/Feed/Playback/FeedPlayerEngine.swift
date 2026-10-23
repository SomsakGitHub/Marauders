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
    private var pausedByUser = false
    private var playbackEnabled = true

    private let mediaPreparation = FeedMediaPreparationService(maxPreparedItems: 5)
    private var bufferingIndicatorTask: Task<Void, Never>?

    private static let stallIndicatorDelayNs: UInt64 = 380_000_000

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
            playbackEnabled = true
            player.play()
            updatePhaseFromVisiblePlayer()
        }
    }

    /// Settles on a page after paging — swaps to preloaded hidden slot when possible.
    func settle(on url: URL, prefetchNeighbors: [URL]) {
        guard validateHTTPS(url) else { return }
        pausedByUser = false
        playbackEnabled = true

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
        playbackEnabled = false
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
        playbackEnabled = true
        pausedByUser = false
        visibleSlot.player.play()
        updatePhaseFromVisiblePlayer()
    }

    func retry() {
        guard let url = currentURL else { return }
        Task { await mediaPreparation.discardPreparedItem(for: url) }
        currentURL = url
        playbackEnabled = true
        pausedByUser = false
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
        guard hidden.loadedURL == url, hidden.requestedURL == url,
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
        guard let next = Self.preloadTarget(currentURL: currentURL, neighbors: urls),
              hiddenSlot.requestedURL != next else { return }
        load(into: hiddenSlot, url: next, autoplay: false)
    }

    static func preloadTarget(currentURL: URL?, neighbors: [URL]) -> URL? {
        neighbors.first { $0 != currentURL && $0.scheme?.lowercased() == "https" }
    }

    private func playOnVisible(url: URL) {
        load(into: visibleSlot, url: url, autoplay: true)
    }

    private func load(
        into slot: PlayerSlot,
        url: URL,
        autoplay: Bool
    ) {
        let requestID = slot.beginRequest(url: url)

        if autoplay {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }

            if let cached = await self.mediaPreparation.consumePreparedItem(for: url) {
                guard slot.requestID == requestID else { return }
                slot.assign(
                    item: cached,
                    url: url,
                    autoplay: autoplay,
                    engine: self
                )
                return
            }

            do {
                guard let item = try await self.mediaPreparation.beginPlaybackItem(for: url) else {
                    if slot.requestID == requestID, autoplay { self.failPlayback(message: "Couldn’t load video") }
                    return
                }
                guard slot.requestID == requestID else { return }
                slot.assign(
                    item: item,
                    url: url,
                    autoplay: autoplay,
                    engine: self
                )
            } catch {
                guard slot.requestID == requestID, autoplay else { return }
                self.failPlayback(message: error.localizedDescription)
            }
        }
    }

    private func validateHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            phase = .failed("URL is not secure")
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
    private(set) var requestedURL: URL?
    private(set) var requestID = UUID()

    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(layer: AVPlayerLayer) {
        self.layer = layer
        player = AVPlayer()
        layer.player = player
    }

    func beginRequest(url: URL) -> UUID {
        clearObservers()
        requestID = UUID()
        requestedURL = url
        return requestID
    }

    func assign(
        item: AVPlayerItem,
        url: URL,
        autoplay: Bool,
        engine: FeedPlayerEngine
    ) {
        loadedURL = url
        player.automaticallyWaitsToMinimizeStalling = true

        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak engine] item, _ in
            Task { @MainActor in
                guard let self, let engine, engine.isVisible(self), self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    AppLog.info("player", "ready host=\(url.host ?? "?")")
                    engine.updatePhaseFromVisiblePlayer()
                case .failed:
                    let message = item.error?.localizedDescription ?? "Playback failed"
                    engine.failPlaybackFromSlot(message: message)
                default:
                    break
                }
            }
        }

        do {
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak engine] _, _ in
                Task { @MainActor in
                    guard let self, let engine, engine.isVisible(self) else { return }
                    engine.updatePhaseFromVisiblePlayer()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.player.currentItem === item else { return }
                self.player.seek(to: .zero) { [weak self, weak engine] finished in
                    Task { @MainActor in
                        guard finished, let self, let engine,
                              engine.shouldPlay(self), self.player.currentItem === item else { return }
                        self.player.play()
                    }
                }
            }
        }

        player.replaceCurrentItem(with: item)

        if autoplay && engine.shouldPlay(self) {
            player.play()
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
    fileprivate func isVisible(_ slot: PlayerSlot) -> Bool {
        slot === visibleSlot
    }

    fileprivate func shouldPlay(_ slot: PlayerSlot) -> Bool {
        isVisible(slot) && playbackEnabled && !pausedByUser
    }

    fileprivate func failPlaybackFromSlot(message: String) {
        failPlayback(message: message)
    }


}
