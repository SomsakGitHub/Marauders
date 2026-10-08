//
//  FeedPlayerSurface.swift
//  Marauders
//

import AVFoundation
import SwiftUI

struct FeedPlayerSurface: UIViewRepresentable {
    let engine: FeedPlayerEngine

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        view.attach(layer: engine.playerLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? PlayerLayerHostView)?.attach(layer: engine.playerLayer)
    }
}

private final class PlayerLayerHostView: UIView {
    private weak var attachedLayer: CALayer?

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
