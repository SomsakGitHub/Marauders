//
//  FeedPlayerLayerHost.swift
//  Marauders
//

import AVFoundation
import UIKit

/// Hosts a shared `AVPlayerLayer` (one instance for the whole feed).
final class FeedPlayerLayerHostView: UIView {
    private weak var attachedLayer: AVPlayerLayer?
    private var readinessObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(layer: AVPlayerLayer) {
        if attachedLayer === layer, layer.superlayer === self.layer {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        readinessObservation?.invalidate()
        attachedLayer?.removeFromSuperlayer()
        attachedLayer = layer
        layer.isHidden = !layer.isReadyForDisplay
        layer.frame = bounds
        self.layer.addSublayer(layer)
        readinessObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] observed, _ in
            let ready = observed.isReadyForDisplay
            let identity = ObjectIdentifier(observed)
            Task { @MainActor in
                guard let self, let current = self.attachedLayer, ObjectIdentifier(current) == identity else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                current.isHidden = !ready
                CATransaction.commit()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer?.frame = bounds
        CATransaction.commit()
    }
}
