import AVFoundation
import Observation

enum FeedPlayerPhase: Equatable, Sendable {
    case idle, buffering, playing, paused
    case failed(String)
}

/// A surface belongs to a media URL, not to the currently selected page.
struct FeedPlayerPresentation: Identifiable {
    let id: Int
    let url: URL?
    let layer: AVPlayerLayer
}

@MainActor
@Observable
final class FeedPlayerEngine {
    private(set) var phase: FeedPlayerPhase = .idle
    private(set) var showsBufferingIndicator = false
    private(set) var presentations: [FeedPlayerPresentation]
    private(set) var visibleSlotIndex = 0
    var playerLayer: AVPlayerLayer { presentations[visibleSlotIndex].layer }

    private let slots: [PlayerSlot]
    private var currentURL: URL?
    private var neighbors: [URL] = []
    private var pausedByUser = false
    private var playbackEnabled = true
    private var firstPlaybackStarted: TimeInterval?
    private var didMeasureFirstPlayback = false
    private var didMeasureFirstReady = false
    private var bufferingIndicatorTask: Task<Void, Never>?
    private let mediaPreparation = FeedMediaPreparationService(
        maxPreparedItems: 5, startupCache: AppRuntimeConfiguration.isUITesting ? nil : FeedStartupCache.shared
    )
    private var visibleSlot: PlayerSlot { slots[visibleSlotIndex] }

    init() {
        let pool = (0..<3).map { _ in PlayerSlot() }
        slots = pool
        presentations = pool.enumerated().map { FeedPlayerPresentation(id: $0.offset, url: nil, layer: $0.element.layer) }
    }

    func settle(on url: URL, prefetchNeighbors: [URL]) {
        guard url.scheme?.lowercased() == "https" else {
            failPlayback(message: "URL is not secure")
            return
        }
        pausedByUser = false
        playbackEnabled = true
        neighbors = Self.previewTargets(currentURL: url, neighbors: prefetchNeighbors)
        if firstPlaybackStarted == nil {
            firstPlaybackStarted = ProcessInfo.processInfo.systemUptime
            AppLog.timing("firstVideo.requested", since: AppLog.launchUptime)
        }
        if currentURL == url, visibleSlot.requestedURL == url, !visibleSlot.loadFailed,
           visibleSlot.player.currentItem?.status != .failed {
            playVisibleIfLoaded()
            prepareNeighbors()
            return
        }

        visibleSlot.player.pause()
        visibleSlot.player.isMuted = true
        currentURL = url
        phase = .buffering
        scheduleBufferingIndicatorIfNeeded()
        if let readyIndex = slots.firstIndex(where: { $0.requestedURL == url }) {
            // Retain both its buffer and its page-bound surface, even if still loading.
            visibleSlotIndex = readyIndex
            if visibleSlot.loadFailed || visibleSlot.player.currentItem?.status == .failed {
                load(into: readyIndex, url: url)
            } else {
                visibleSlot.player.cancelPendingPrerolls()
                visibleSlot.player.isMuted = false
                playVisibleIfLoaded()
            }
        } else {
            load(into: visibleSlotIndex, url: url)
        }
        prepareNeighbors()
    }

    func play(url: URL) { settle(on: url, prefetchNeighbors: []) }

    func togglePlayPause() {
        if visibleSlot.player.timeControlStatus == .playing { pause(byUser: true) }
        else { resume() }
    }

    func pause(byUser: Bool = false) {
        playbackEnabled = false
        for slot in slots {
            slot.player.pause()
            slot.cancelPreview()
        }
        if byUser { pausedByUser = true }
        phase = .paused
        hideBufferingIndicator()
    }

    func resume() {
        playbackEnabled = true
        pausedByUser = false
        playVisibleIfLoaded()
        prepareNeighbors()
    }

    func retry() {
        guard let url = currentURL else { return }
        playbackEnabled = true
        pausedByUser = false
        load(into: visibleSlotIndex, url: url)
    }

    func prefetch(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        let protected = Set(slots.compactMap(\.requestedURL))
        let service = mediaPreparation
        Task.detached(priority: .utility) { await service.prefetch(url: url, protected: protected) }
    }
    func warmURLs(_ urls: [URL]) { for url in urls { prefetch(url: url) } }

    static func previewTargets(currentURL: URL?, neighbors: [URL]) -> [URL] {
        var result: [URL] = []
        for url in neighbors where url != currentURL && url.scheme?.lowercased() == "https" {
            if !result.contains(url) { result.append(url) }
            if result.count == 2 { break }
        }
        return result
    }
    static func preloadTarget(currentURL: URL?, neighbors: [URL]) -> URL? {
        previewTargets(currentURL: currentURL, neighbors: neighbors).first
    }

    private func prepareNeighbors() {
        guard playbackEnabled else { return }
        let desired = Set(neighbors)
        for url in neighbors {
            if let existing = slots.firstIndex(where: { $0.requestedURL == url }) {
                if slots[existing].loadFailed || slots[existing].player.currentItem?.status == .failed {
                    load(into: existing, url: url)
                }
                else if existing != visibleSlotIndex { slots[existing].preparePreview() }
                continue
            }
            guard let index = slots.indices.first(where: {
                $0 != visibleSlotIndex && slots[$0].requestedURL.map { !desired.contains($0) } != false
            }) else { continue }
            load(into: index, url: url)
        }
    }

    private func playVisibleIfLoaded() {
        guard playbackEnabled, !pausedByUser,
              visibleSlot.loadedURL == currentURL, visibleSlot.player.currentItem != nil else { return }
        visibleSlot.player.isMuted = false
        visibleSlot.player.play()
        updatePhaseFromVisiblePlayer()
    }

    private func load(into index: Int, url: URL) {
        let slot = slots[index]
        let requestID = slot.beginRequest(url: url)
        presentations[index] = FeedPlayerPresentation(id: index, url: url, layer: slot.layer)
        if index == visibleSlotIndex {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }
        slot.loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = await mediaPreparation.consumePreparedItem(for: url)
                let item: AVPlayerItem?
                if let prepared { item = prepared }
                else { item = try await mediaPreparation.beginPlaybackItem(for: url) }
                guard !Task.isCancelled, slot.requestID == requestID else { return }
                guard let item else {
                    slot.recordLoadFailure()
                    if isVisible(slot) { failPlayback(message: "Couldn’t load video") }
                    return
                }
                slot.assign(item: item, url: url, engine: self)
            } catch {
                guard !Task.isCancelled, slot.requestID == requestID else { return }
                slot.recordLoadFailure()
                if isVisible(slot) { failPlayback(message: error.localizedDescription) }
            }
        }
    }

    fileprivate func isVisible(_ slot: PlayerSlot) -> Bool { slot === visibleSlot }
    fileprivate func shouldPlay(_ slot: PlayerSlot) -> Bool { isVisible(slot) && playbackEnabled && !pausedByUser }
    fileprivate func shouldPreview(_ slot: PlayerSlot) -> Bool { !isVisible(slot) && playbackEnabled }

    fileprivate func itemFailed(in slot: PlayerSlot, item: AVPlayerItem, url: URL) async {
        guard isVisible(slot), slot.player.currentItem === item else { return }
        if (item.asset as? AVURLAsset)?.url.isFileURL == true {
            await mediaPreparation.invalidateLocalFile(for: url)
            guard currentURL == url, slot.player.currentItem === item else { return }
            load(into: visibleSlotIndex, url: url)
        } else { failPlayback(message: item.error?.localizedDescription ?? "Playback failed") }
    }

    fileprivate func updatePhaseFromVisiblePlayer() {
        guard playbackEnabled, !pausedByUser, visibleSlot.loadedURL == currentURL else { return }
        let player = visibleSlot.player
        guard player.currentItem?.status != .failed else { return }
        if player.currentItem?.status == .readyToPlay, !didMeasureFirstReady, let start = firstPlaybackStarted {
            didMeasureFirstReady = true
            AppLog.timing("firstVideo.ready", since: start)
        }
        if player.timeControlStatus == .playing {
            if !didMeasureFirstPlayback, let start = firstPlaybackStarted {
                didMeasureFirstPlayback = true
                AppLog.timing("firstVideo.playing", since: start)
            }
            phase = .playing
            hideBufferingIndicator()
        } else {
            phase = .buffering
            scheduleBufferingIndicatorIfNeeded()
        }
    }
    private func failPlayback(message: String) { phase = .failed(message); hideBufferingIndicator() }
    private func scheduleBufferingIndicatorIfNeeded() {
        guard bufferingIndicatorTask == nil else { return }
        bufferingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, let self, self.phase == .buffering else { return }
            self.showsBufferingIndicator = true
        }
    }
    private func hideBufferingIndicator() {
        bufferingIndicatorTask?.cancel()
        bufferingIndicatorTask = nil
        showsBufferingIndicator = false
    }
}

@MainActor
private final class PlayerSlot {
    let player = AVPlayer()
    private(set) var layer = AVPlayerLayer()
    private(set) var loadedURL: URL?
    private(set) var requestedURL: URL?
    private(set) var requestID = UUID()
    private(set) var loadFailed = false
    var loadTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var prerollRequested = false

    init() {
        layer.videoGravity = .resizeAspectFill
        layer.player = player
        player.automaticallyWaitsToMinimizeStalling = true
    }
    func beginRequest(url: URL) -> UUID {
        loadTask?.cancel()
        player.cancelPendingPrerolls()
        player.pause()
        clearObservers()
        layer.player = nil
        layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        loadFailed = false
        requestedURL = url
        requestID = UUID()
        prerollRequested = false
        return requestID
    }
    func assign(item: AVPlayerItem, url: URL, engine: FeedPlayerEngine) {
        loadedURL = url
        player.isMuted = !engine.isVisible(self)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak engine] item, _ in
            Task { @MainActor in
                guard let self, let engine, self.player.currentItem === item else { return }
                if item.status == .failed { await engine.itemFailed(in: self, item: item, url: url) }
                else if engine.isVisible(self) { engine.updatePhaseFromVisiblePlayer() }
                else if engine.shouldPreview(self) { self.preparePreview() }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak engine] _, _ in
            Task { @MainActor in
                guard let self, let engine, engine.isVisible(self) else { return }
                engine.updatePhaseFromVisiblePlayer()
            }
        }
        playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self, weak engine] _, _ in
            Task { @MainActor in
                guard let self, let engine, engine.shouldPreview(self) else { return }
                self.preparePreview()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.player.currentItem === item else { return }
                self.player.seek(to: .zero) { [weak self, weak engine] finished in
                    Task { @MainActor in
                        guard finished, let self, let engine, engine.shouldPlay(self), self.player.currentItem === item else { return }
                        self.player.play()
                    }
                }
            }
        }
        player.replaceCurrentItem(with: item)
        layer.player = player
        if engine.shouldPlay(self) { player.play() }
        else if engine.shouldPreview(self) { preparePreview() }
    }
    func cancelPreview() {
        player.cancelPendingPrerolls()
        prerollRequested = false
    }
    func recordLoadFailure() { loadFailed = true }

    func preparePreview() {
        guard !prerollRequested, player.isMuted, player.status == .readyToPlay,
              player.currentItem?.status == .readyToPlay else { return }
        prerollRequested = true
        player.preroll(atRate: 1) { _ in }
    }
    private func clearObservers() {
        statusObservation = nil
        playerStatusObservation = nil
        timeControlObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
