//
//  FeedPlayerLayerHost.swift
//  Marauders
//

import AVFoundation
import UIKit

/// Hosts a shared `AVPlayerLayer` (one instance for the whole feed).
final class FeedPlayerLayerHostView: UIView {
    private weak var attachedLayer: AVPlayerLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(layer: AVPlayerLayer) {
        if attachedLayer === layer, layer.superlayer === self.layer {
            return
        }
        attachedLayer?.removeFromSuperlayer()
        attachedLayer = layer
        layer.frame = bounds
        self.layer.addSublayer(layer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachedLayer?.frame = bounds
    }
}
