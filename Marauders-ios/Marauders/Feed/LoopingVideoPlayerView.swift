//
//  LoopingVideoPlayerView.swift
//  Marauders
//

import AVFoundation
import SwiftUI

struct LoopingVideoPlayerView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.teardown()
    }
}

// MARK: - UIKit player

final class PlayerContainerView: UIView {
    private var playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var currentURL: URL?

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

    func configure(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        if currentURL == url, queuePlayer != nil {
            return
        }

        teardown()
        currentURL = url

        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                let description = item.error?.localizedDescription ?? "unknown"
                AppLog.error("player", "failed urlHost=\(url.host ?? "?") error=\(description)")
            }
        }

        let player = AVQueuePlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none

        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        playerLayer.player = player
    }

    func setPlaying(_ isPlaying: Bool) {
        guard let player = queuePlayer else { return }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    func teardown() {
        statusObservation?.invalidate()
        statusObservation = nil
        queuePlayer?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer = nil
        playerLayer.player = nil
        currentURL = nil
    }
}
