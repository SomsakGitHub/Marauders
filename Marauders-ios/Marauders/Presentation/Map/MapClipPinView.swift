//
//  MapClipPinView.swift
//  Marauders
//

import SwiftUI

struct MapClipPinView: View {
    let clip: FeedVideo

    @State private var thumbnail: UIImage?

    private let pinWidth: CGFloat = 48
    private let pinHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                thumbnailContent
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
            .frame(width: pinWidth, height: pinHeight - 8)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            MapPinTail()
                .fill(.white)
                .frame(width: 14, height: 8)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip preview on map")
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
                colors: [Color(white: 0.35), Color(white: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }
}

private struct MapPinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
