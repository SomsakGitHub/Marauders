//
//  FeedClipCaptionOverlay.swift
//  Marauders
//

import SwiftUI

/// How the feed's caption is cut: three lines, two at accessibility text sizes, and when that hides any text.
enum FeedCaptionClamp {
    static func lineLimit(accessibilitySize: Bool) -> Int {
        accessibilitySize ? 2 : 3
    }

    /// Whether the text is taller than the lines shown. The two heights come from two layouts of the same text, so a
    /// difference of up to one point is rounding, not a hidden line.
    static func isCut(fullHeight: CGFloat, clampedHeight: CGFloat) -> Bool {
        fullHeight - clampedHeight > 1
    }
}

/// The darkening under the caption and the rail: a layer of its own over the whole clip, so it does not follow the
/// caption's width. It ignores touches so feed paging and tap-to-play keep working.
struct FeedCaptionScrim: View {
    var body: some View {
        LinearGradient(
            colors: [.black.opacity(0.0), .black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Bottom-left caption for the current feed clip, in the row it shares with the action rail. The author is shown only
/// as the avatar in the action rail.
///
/// The caption shows three lines (two at accessibility text sizes). When that hides text, "more" opens the whole
/// caption in a block that scrolls when it is longer than `maxOpenHeight`, and "less" closes it. While it only shows
/// lines the caption ignores touches, so feed paging, tap-to-play and double tap to like keep working over it. VoiceOver
/// reads all of the caption either way. Give the view the clip's identity (`.id`) so a new clip starts closed.
struct FeedClipCaptionOverlay: View {
    let clip: FeedVideo
    /// The tallest the opened caption may be.
    let maxOpenHeight: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isOpen = false
    /// The caption's height with every line, and with only the lines shown: the difference says whether text is hidden.
    /// Measured while the caption is closed; an opened caption keeps the last readings.
    @State private var fullHeight: CGFloat = 0
    @State private var clampedHeight: CGFloat = 0

    private var isCut: Bool {
        FeedCaptionClamp.isCut(fullHeight: fullHeight, clampedHeight: clampedHeight)
    }

    var body: some View {
        // Always as wide as the room it is given, caption or not, so the rail keeps the right edge of the row.
        VStack(alignment: .leading, spacing: 0) {
            if let caption = Self.cleaned(clip.caption) {
                if isOpen {
                    openCaption(caption)
                } else {
                    closedCaption(caption)
                }
                if isCut || isOpen {
                    toggle
                }
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styled(_ caption: String) -> some View {
        Text(caption)
            .font(.subheadline)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .accessibilityIdentifier("feed.caption")
    }

    private func closedCaption(_ caption: String) -> some View {
        styled(caption)
            .lineLimit(FeedCaptionClamp.lineLimit(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                clampedHeight = $0
            }
            .background(alignment: .topLeading) {
                // The same text with every line, laid out in the same width, only to be measured.
                Text(caption)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        fullHeight = $0
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
    }

    /// As tall as the caption needs, up to `maxOpenHeight`; a longer one scrolls inside, and takes touches to do it.
    private func openCaption(_ caption: String) -> some View {
        ViewThatFits(in: .vertical) {
            styled(caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            ScrollView {
                styled(caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: maxOpenHeight)
        // A long text is read, not glanced at, and its upper lines lie where the scrim is thin: over a bright clip they
        // went pale. A plate of its own, around the opened block only, keeps them readable.
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.35))
                .padding(-6)
                .allowsHitTesting(false)
        }
    }

    /// The only part of the caption that takes touches while it is closed. Its own word is its label, so Voice Control
    /// says what it sees.
    private var toggle: some View {
        Button {
            withAnimation(.snappy) { isOpen.toggle() }
        } label: {
            (isOpen ? Text("less") : Text("more"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                // At least 44 x 44 points to hit, also for the short Thai word.
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("feed.captionToggle")
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
