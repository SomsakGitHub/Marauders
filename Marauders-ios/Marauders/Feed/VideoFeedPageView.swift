//
//  VideoFeedPageView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedPageView: View {
    let video: FeedVideo
    let isActive: Bool

    var body: some View {
        ZStack {
            LoopingVideoPlayerView(url: video.streamURL, isActive: isActive)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                captionBlock
                Spacer(minLength: 0)
                actionRail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Color.black)
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.authorName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text(video.caption)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(3)

            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.caption)
                Text(video.musicTitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRail: some View {
        VStack(spacing: 22) {
            feedAction(icon: "person.crop.circle.fill", label: "โปรไฟล์")
            feedAction(icon: "heart.fill", label: "12.4K")
            feedAction(icon: "bubble.right.fill", label: "348")
            feedAction(icon: "arrowshape.turn.up.right.fill", label: "แชร์")
        }
        .foregroundStyle(.white)
    }

    private func feedAction(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
            Text(label)
                .font(.caption2.weight(.medium))
        }
    }
}
