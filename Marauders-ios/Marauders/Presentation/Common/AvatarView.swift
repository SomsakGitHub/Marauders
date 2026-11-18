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

    /// The gradient pairs behind the white initial. Fixed colours, the same in light and dark: the system colours they
    /// replace were too light for white text (the yellow pair reached 1.5:1) and shift between the two appearances. Each
    /// is 60% of that system colour's light value, so every stop carries white at 4.5:1 or better (the worst, orange,
    /// reaches 5.55:1) and the pairs keep their hues.
    static let palettes: [[Color]] = {
        func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
            Color(red: red / 255, green: green / 255, blue: blue / 255)
        }
        let orange = rgb(153, 89, 0)
        let pink = rgb(153, 27, 51)
        let blue = rgb(0, 73, 153)
        let purple = rgb(105, 49, 133)
        let teal = rgb(29, 106, 119)
        let indigo = rgb(53, 52, 128)
        let red = rgb(153, 35, 29)
        let green = rgb(31, 119, 53)
        return [
            [orange, pink],
            [blue, purple],
            [teal, indigo],
            [pink, red],
            [green, blue],
            [purple, pink],
        ]
    }()

    /// Which pair a handle gets: always the same one for the same handle, so nobody's avatar changes colour.
    static func paletteIndex(for handle: String?) -> Int {
        let seed = handle?.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffffff } ?? 0
        return seed % palettes.count
    }

    private static func gradient(for handle: String?) -> LinearGradient {
        LinearGradient(colors: palettes[paletteIndex(for: handle)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
