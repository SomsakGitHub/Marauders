//
//  FeedClipActionRail.swift
//  Marauders
//

import SwiftUI

/// Right-edge action rail for the current clip (TikTok-style). For now it hosts
/// the creator's avatar, which opens their public profile when tapped.
struct FeedClipActionRail: View {
    let clip: FeedVideo
    var onChooseThai: (() -> Void)? = nil
    var onAuthorTap: ((String) -> Void)?

    @State private var choosingAudio = false

    var body: some View {
        VStack(spacing: 20) {
            if let onChooseThai, clip.allowsThaiAudio {
                Button { choosingAudio = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform").font(.title2)
                        Text("เลือกเสียง").font(.caption)
                    }.foregroundStyle(.white)
                }
                .accessibilityIdentifier("feed.chooseAudio")
                .confirmationDialog("เลือกเสียงสำหรับคลิปนี้", isPresented: $choosingAudio, titleVisibility: .visible) {
                    Button("ฟังเสียงต้นฉบับ") {}
                    Button("แปลเป็นเสียงไทยด้วย AI", action: onChooseThai)
                    Button("ยกเลิก", role: .cancel) {}
                } message: { Text("ใช้เสียงแปลไทยจาก AI ที่เก็บไว้ หรือสร้างบน iPhone และเก็บให้ผู้ชมคนอื่นใช้ซ้ำได้") }
            }

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
