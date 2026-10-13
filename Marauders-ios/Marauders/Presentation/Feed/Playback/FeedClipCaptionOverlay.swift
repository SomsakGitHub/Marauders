//
//  FeedClipCaptionOverlay.swift
//  Marauders
//

import SwiftUI

/// Bottom-left caption block for the current feed clip (author, caption).
/// The author line is tappable when `onAuthorTap` is provided; everything else
/// ignores touches so feed paging and tap-to-play keep working.
struct FeedClipCaptionOverlay: View {
    let clip: FeedVideo
    var onAuthorTap: ((String) -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 6) {
                authorName
                if let caption = Self.cleaned(clip.caption) {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var authorName: some View {
        if let authorName = clip.authorName {
            if let onAuthorTap {
                Button {
                    onAuthorTap(authorName)
                } label: {
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.author")
            } else {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
