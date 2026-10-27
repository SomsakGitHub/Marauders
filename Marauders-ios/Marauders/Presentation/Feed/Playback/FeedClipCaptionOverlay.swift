//
//  FeedClipCaptionOverlay.swift
//  Marauders
//

import SwiftUI

/// Bottom-left caption for the current feed clip. The author is shown only as the avatar in the action rail.
/// The caption ignores touches so feed paging and tap-to-play keep working.
struct FeedClipCaptionOverlay: View {
    let clip: FeedVideo

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

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
