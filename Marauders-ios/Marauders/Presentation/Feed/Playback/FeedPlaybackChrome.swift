//
//  FeedPlaybackChrome.swift
//  Marauders
//

import SwiftUI

/// Paused indicator; passes touches through for paging.
struct FeedPlaybackChrome: View {
    @Bindable var engine: FeedPlayerEngine

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if engine.phase == .paused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.35), radius: 8)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: engine.phase == .paused)
    }
}
