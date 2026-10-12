//
//  MapClipShelf.swift
//  Marauders
//

import SwiftUI

/// A draggable bottom panel that lists the clips currently visible on the map,
/// matching the way Instagram surfaces nearby places under its map.
struct MapClipShelf: View {
    let clips: [FeedVideo]
    let isSearching: Bool
    @Binding var isExpanded: Bool
    let onSelect: (FeedVideo) -> Void

    @State private var dragTranslation: CGFloat = 0

    private let peekHeight: CGFloat = 168
    private let expandedHeight: CGFloat = 430
    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3)]

    private var height: CGFloat {
        let base = isExpanded ? expandedHeight : peekHeight
        return max(peekHeight * 0.6, base - max(0, dragTranslation))
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: -4)
        .gesture(dragGesture)
        .accessibilityIdentifier("map.shelf")
    }

    private var grabber: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse clip list" : "Expand clip list")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if clips.isEmpty {
            emptyState
        } else if isExpanded {
            grid
        } else {
            horizontalStrip
        }
    }

    private var title: String {
        if clips.isEmpty {
            return isSearching ? "No matching clips" : "No clips here"
        }
        let noun = clips.count == 1 ? "clip" : "clips"
        return isSearching ? "\(clips.count) \(noun) found" : "\(clips.count) \(noun) here"
    }

    private var horizontalStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(clips) { clip in
                    Button { onSelect(clip) } label: {
                        MapShelfThumbnail(clip: clip, size: 96)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(clips) { clip in
                    Button { onSelect(clip) } label: {
                        MapShelfThumbnail(clip: clip, size: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "map")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(isSearching
                 ? "Try a country name or an @handle"
                 : "Pan or zoom the map to find clips")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let shouldExpand: Bool
                if value.translation.height < -40 {
                    shouldExpand = true
                } else if value.translation.height > 40 {
                    shouldExpand = false
                } else {
                    shouldExpand = isExpanded
                }
                withAnimation(.snappy) {
                    isExpanded = shouldExpand
                    dragTranslation = 0
                }
            }
    }
}

/// A square clip thumbnail used inside the shelf.
struct MapShelfThumbnail: View {
    let clip: FeedVideo
    let size: CGFloat?

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.25)
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let caption = clip.caption, !caption.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
            }
        }
        .task(id: clip.streamURL) {
            thumbnail = await VideoThumbnailLoader.shared.thumbnail(for: clip.streamURL, maxPixelSize: 200)
        }
    }
}
