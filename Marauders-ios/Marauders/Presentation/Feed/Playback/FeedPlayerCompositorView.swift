//
//  FeedPlayerCompositorView.swift
//  Marauders
//

import UIKit

/// Stacks two player layers; the visible slot is brought to the front without re-layout churn.
final class FeedPlayerCompositorView: UIView {
    private let hostA = FeedPlayerLayerHostView()
    private let hostB = FeedPlayerLayerHostView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(hostA)
        addSubview(hostB)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sync(with engine: FeedPlayerEngine) {
        hostA.attach(layer: engine.layerA)
        hostB.attach(layer: engine.layerB)
        if engine.visibleSlotIsA {
            bringSubviewToFront(hostA)
        } else {
            bringSubviewToFront(hostB)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostA.frame = bounds
        hostB.frame = bounds
    }
}
