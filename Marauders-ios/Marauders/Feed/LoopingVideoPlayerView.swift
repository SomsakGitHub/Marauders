//
//  LoopingVideoPlayerView.swift
//  Marauders
//

import AVFoundation
import SwiftUI

struct LoopingVideoPlayerView: UIViewRepresentable {
    let url: URL
    let isActive: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        PlayerContainerView()
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.setPlaybackIntent(active: isActive, url: url)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.teardownImmediately()
    }
}

// MARK: - UIKit player

@MainActor
final class PlayerContainerView: UIView {
    private var playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var inactiveTeardownTask: Task<Void, Never>?

    private static let inactiveTeardownDelayNs: UInt64 = 450_000_000

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func setPlaybackIntent(active: Bool, url: URL) {
        inactiveTeardownTask?.cancel()
        inactiveTeardownTask = nil

        guard active else {
            player?.pause()
            inactiveTeardownTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.inactiveTeardownDelayNs)
                guard !Task.isCancelled else { return }
                self?.teardownImmediately()
            }
            return
        }

        if currentURL == url, player != nil {
            player?.play()
            return
        }

        configure(url: url)
        player?.play()
    }

    private func configure(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }

        teardownImmediately()
        currentURL = url

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2

        statusObservation = item.observe(\.status, options: [.new]) { [url] item, _ in
            Task { @MainActor in
                if item.status == .readyToPlay {
                    AppLog.info("player", "ready host=\(url.host ?? "?")")
                } else if item.status == .failed {
                    let description = item.error?.localizedDescription ?? "unknown"
                    let code = (item.error as NSError?)?.code ?? 0
                    AppLog.error("player", "failed host=\(url.host ?? "?") code=\(code) error=\(description)")
                }
            }
        }

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.actionAtItemEnd = .pause

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak avPlayer] _ in
            avPlayer?.seek(to: .zero)
            avPlayer?.play()
        }

        player = avPlayer
        playerLayer.player = avPlayer
        AppLog.debug("player", "configured host=\(url.host ?? "?")")
    }

    func teardownImmediately() {
        inactiveTeardownTask?.cancel()
        inactiveTeardownTask = nil

        if currentURL != nil {
            AppLog.debug("player", "teardown host=\(currentURL?.host ?? "?")")
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerLayer.player = nil
        currentURL = nil
    }
}
