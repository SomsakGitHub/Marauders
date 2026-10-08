//
//  FeedMediaPreparationService.swift
//  Marauders
//

import AVFoundation

/// Off–MainActor AVAsset / AVPlayerItem preparation (network + KVO) for the feed engine.
actor FeedMediaPreparationService {
    private var assetsByURL: [URL: AVURLAsset] = [:]
    private var preparedItems: [URL: AVPlayerItem] = [:]
    private var preparingURLs: Set<URL> = []

    private let maxPreparedItems: Int
    private let forwardBufferDuration: TimeInterval

    init(maxPreparedItems: Int = 5, forwardBufferDuration: TimeInterval = 6) {
        self.maxPreparedItems = maxPreparedItems
        self.forwardBufferDuration = forwardBufferDuration
    }

    func consumePreparedItem(for url: URL) -> AVPlayerItem? {
        preparedItems.removeValue(forKey: url)
    }

    func discardPreparedItem(for url: URL) {
        preparedItems.removeValue(forKey: url)
    }

    /// Item for visible-slot playback — checks `isPlayable` only; readiness comes from KVO on the engine.
    func beginPlaybackItem(for url: URL) async throws -> AVPlayerItem? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let asset = await asset(for: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { return nil }
        return makePlayerItem(asset: asset)
    }

    /// Warms `preparedItems` when not already cached or in flight.
    func prefetch(url: URL, protected: Set<URL>) async {
        guard url.scheme?.lowercased() == "https" else { return }
        guard preparedItems[url] == nil, !preparingURLs.contains(url) else { return }

        preparingURLs.insert(url)
        trimCaches(keeping: protected.union([url]))

        let asset = await asset(for: url)
        guard let ready = await prepareItem(asset: asset) else {
            preparingURLs.remove(url)
            return
        }

        preparingURLs.remove(url)
        guard preparedItems[url] == nil else { return }
        preparedItems[url] = ready
        trimCaches(keeping: protected.union([url]))
        await MainActor.run {
            AppLog.debug("player", "prepared item host=\(url.host ?? "?")")
        }
    }

    func trimCaches(keeping protected: Set<URL>) {
        if assetsByURL.count > maxPreparedItems + 2 {
            for key in assetsByURL.keys where !protected.contains(key) && preparedItems[key] == nil {
                assetsByURL.removeValue(forKey: key)
                if assetsByURL.count <= maxPreparedItems + 2 { break }
            }
        }

        if preparedItems.count > maxPreparedItems {
            for key in preparedItems.keys where !protected.contains(key) {
                preparedItems.removeValue(forKey: key)
                if preparedItems.count <= maxPreparedItems { break }
            }
        }
    }

    // MARK: - Private

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
        item.preferredForwardBufferDuration = forwardBufferDuration
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
}
