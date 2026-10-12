//
//  MapClusterPinView.swift
//  Marauders
//

import SwiftUI

/// A map pin that either previews a single clip or, when several clips are
/// grouped together, shows how many clips the cluster contains.
struct MapClusterPinView: View {
    let cluster: MapClipCluster
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if cluster.isCluster {
                clusterBubble
            } else if let clip = cluster.clips.first {
                MapClipPinView(clip: clip)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map.clipPin")
    }

    private var clusterBubble: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 52, height: 52)

            Text("\(cluster.clips.count)")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cluster.clips.count) clips grouped here")
    }
}
