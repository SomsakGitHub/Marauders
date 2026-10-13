//
//  FeedClipCaptionOverlay.swift
//  Marauders
//

import SwiftUI

/// Bottom-left caption block for the current feed clip (author, caption, music).
struct FeedClipCaptionOverlay: View {
    let clip: FeedVideo

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                if let authorName = clip.authorName {
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                }
                if let caption = Self.cleaned(clip.caption) {
                    Text(caption)
                        .font(.subheadline)
                }
                if let musicTitle = Self.cleaned(clip.musicTitle) {
                    Label(musicTitle, systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
        .allowsHitTesting(false)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
