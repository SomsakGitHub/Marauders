//
//  FeedClipActionRail.swift
//  Marauders
//

import SwiftUI

/// Right-edge action rail for the current clip (TikTok-style). For now it hosts
/// the creator's avatar, which opens their public profile when tapped.
struct FeedClipActionRail: View {
    let clip: FeedVideo
    var onAuthorTap: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            if let handle = clip.authorName {
                Button {
                    onAuthorTap?(handle)
                } label: {
                    AvatarView(url: clip.authorAvatarURL, handle: handle, size: 48)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.avatar")
                .accessibilityLabel("Open \(handle) profile")
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
