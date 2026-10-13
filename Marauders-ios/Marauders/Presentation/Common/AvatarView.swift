//
//  AvatarView.swift
//  Marauders
//

import SwiftUI

/// Circular profile avatar. Shows the remote image when available, otherwise a
/// deterministic gradient placeholder derived from the handle (TikTok-style).
struct AvatarView: View {
    let url: URL?
    let handle: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Self.gradient(for: handle))

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholderGlyph
                    default:
                        ProgressView().tint(.white)
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
        .accessibilityHidden(true)
    }

    private var placeholderGlyph: some View {
        Group {
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(.white)
            }
        }
    }

    private var initial: String? {
        guard let handle else { return nil }
        let body = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        guard let first = body.first, first.isLetter || first.isNumber else { return nil }
        return String(first).uppercased()
    }

    private static let palettes: [[Color]] = [
        [.orange, .pink],
        [.blue, .purple],
        [.teal, .indigo],
        [.pink, .red],
        [.green, .blue],
        [.yellow, .orange],
    ]

    private static func gradient(for handle: String?) -> LinearGradient {
        let seed = handle?.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffffff } ?? 0
        let colors = palettes[seed % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
