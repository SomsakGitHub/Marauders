//
//  AvatarPaletteTests.swift
//  Marauders
//

import SwiftUI
import Testing
import UIKit

@testable import Marauders

/// The avatar placeholder is a gradient with a white initial on it. Every colour of it must carry white text
/// (4.5:1, in light and in dark), and every handle must keep the pair it has today: nobody's colour changes under them.
@MainActor
struct AvatarPaletteTests {
    /// WCAG relative luminance of `color` as it looks in one appearance.
    private func luminance(of color: Color, in style: UIUserInterfaceStyle) -> Double {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// White text on `color`: `1.05 / (L + 0.05)`.
    private func contrastWithWhite(_ color: Color, in style: UIUserInterfaceStyle) -> Double {
        1.05 / (luminance(of: color, in: style) + 0.05)
    }

    @Test func everyGradientStopReachesFourPointFiveToOneInLightAndDark() {
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            for (paletteIndex, palette) in AvatarView.palettes.enumerated() {
                for (stopIndex, stop) in palette.enumerated() {
                    let ratio = contrastWithWhite(stop, in: style)
                    #expect(
                        ratio >= 4.5,
                        "palette \(paletteIndex), stop \(stopIndex), \(name): white on it is \(ratio):1")
                }
            }
        }
    }

    @Test func thePalettesAreStillSix() {
        #expect(AvatarView.palettes.count == 6)
        #expect(AvatarView.palettes.allSatisfy { $0.count == 2 })
    }

    /// The pairs people have today, computed from the seed code before the colours changed.
    @Test(
        arguments: [
            ("@a", 5), ("@b", 0), ("@c", 1), ("@d", 2), ("@g", 5), ("@bob", 5), ("@carol", 5), ("@traveler", 3),
            ("@marauders", 4), ("@stream0", 2), ("@stream1", 3), ("@stream3", 5), ("@alice", 4),
        ])
    func aHandleKeepsItsPalette(handle: String, index: Int) {
        #expect(AvatarView.paletteIndex(for: handle) == index)
    }

    @Test func oddHandlesStillGetAPalette() {
        #expect(AvatarView.paletteIndex(for: nil) == 0)
        #expect(AvatarView.paletteIndex(for: "") == 0)
        for handle in ["@😀", "ก", "@" + String(repeating: "x", count: 10_000)] {
            let index = AvatarView.paletteIndex(for: handle)
            #expect((0..<AvatarView.palettes.count).contains(index), "\(handle.prefix(12)) gave \(index)")
        }
    }
}
