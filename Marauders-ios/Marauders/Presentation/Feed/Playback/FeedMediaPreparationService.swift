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

    private let startupCache: (any FeedMediaCaching)?
    private let maxPreparedItems: Int
    private let forwardBufferDuration: TimeInterval

    init(maxPreparedItems: Int = 5, forwardBufferDuration: TimeInterval = 6, startupCache: (any FeedMediaCaching)? = nil) {
        self.startupCache = startupCache
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
        do {
            if try await asset.load(.isPlayable) { return makePlayerItem(asset: asset) }
        } catch {
            if !asset.url.isFileURL { throw error }
        }
        guard asset.url.isFileURL else { return nil }
        await invalidateLocalFile(for: url)
        let remote = await self.asset(for: url)
        guard try await remote.load(.isPlayable) else { return nil }
        return makePlayerItem(asset: remote)
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

    func invalidateLocalFile(for url: URL) async {
        await startupCache?.invalidate(url)
        assetsByURL.removeValue(forKey: url)
        preparedItems.removeValue(forKey: url)
    }

    // MARK: - Private

    private func asset(for url: URL) async -> AVURLAsset {
        if let existing = assetsByURL[url] {
            return existing
        }
        let local = await startupCache?.localURL(for: url)
        if local != nil { await AppLog.info("startup.cache", "playback source=disk") }
        let asset = AVURLAsset(
            url: local ?? url,
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
        // An unattached item cannot be relied on to become readyToPlay.
        // Cache the playable asset's item; the hidden player handles readiness.
        return makePlayerItem(asset: asset)
    }
}
