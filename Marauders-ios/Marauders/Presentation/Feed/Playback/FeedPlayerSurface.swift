//
//  FeedPlayerSurface.swift
//  Marauders
//

import SwiftUI

struct FeedPlayerSurface: UIViewRepresentable {
    let engine: FeedPlayerEngine

    func makeUIView(context: Context) -> FeedPlayerLayerHostView {
        let view = FeedPlayerLayerHostView()
        view.attach(layer: engine.playerLayer)
        return view
    }

    func updateUIView(_ uiView: FeedPlayerLayerHostView, context: Context) {
        uiView.attach(layer: engine.playerLayer)
    }
}
