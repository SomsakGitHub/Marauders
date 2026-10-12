//
//  MapClipPinView.swift
//  Marauders
//

import SwiftUI

/// A single clip rendered as a circular, Instagram-style map pin.
struct MapClipPinView: View {
    let clip: FeedVideo

    @State private var thumbnail: UIImage?

    private let diameter: CGFloat = 54

    var body: some View {
        ZStack {
            thumbnailContent
            Circle()
                .strokeBorder(.white, lineWidth: 3)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip on map")
        .task(id: clip.streamURL) {
            thumbnail = await VideoThumbnailLoader.shared.thumbnail(for: clip.streamURL)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(white: 0.38), Color(white: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
