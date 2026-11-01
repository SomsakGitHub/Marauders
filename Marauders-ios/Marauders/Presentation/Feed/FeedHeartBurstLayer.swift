//
//  FeedHeartBurstLayer.swift
//  Marauders
//

import SwiftUI

extension Color {
    /// The red of a liked heart, on the rail and in a double tap's burst (TikTok's).
    static let likeRed = Color(red: 254 / 255, green: 44 / 255, blue: 85 / 255)
}

/// A big heart a double tap leaves on the clip.
struct FeedHeartBurst: Identifiable, Equatable {
    /// How long a heart takes to pop in, rise and fade; the feed drops it after that.
    static let duration: TimeInterval = 1

    let id = UUID()
    /// Where the finger was, in the feed's own coordinates.
    let location: CGPoint
    /// A slight tilt either way, so a run of hearts does not stand in a straight row.
    let tilt: Angle

    init(location: CGPoint, tilt: Angle = .degrees(.random(in: -25 ... 25))) {
        self.location = location
        self.tilt = tilt
    }
}

/// The hearts double taps leave on the clip, as on TikTok: each pops in where the finger was, tilted a little, then
/// floats up and fades. Touches pass through to the feed, and VoiceOver skips it: the rail's heart says the same.
struct FeedHeartBurstLayer: View {
    let bursts: [FeedHeartBurst]

    var body: some View {
        ZStack {
            ForEach(bursts) { burst in
                FeedHeartBurstView(tilt: burst.tilt)
                    .position(burst.location)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FeedHeartBurstView: View {
    let tilt: Angle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    private struct Frame {
        var scale = 1.4
        var opacity = 0.0
        var rise = 0.0
    }

    var body: some View {
        // With Reduce Motion the heart only fades in and out.
        let still = reduceMotion
        Image(systemName: "heart.fill")
            .font(.system(size: 100))
            .foregroundStyle(Color.likeRed.gradient)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .rotationEffect(tilt)
            .keyframeAnimator(initialValue: Frame(), trigger: isShown) { heart, frame in
                heart
                    .scaleEffect(still ? 1 : frame.scale)
                    .offset(y: still ? 0 : frame.rise)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                // Pops in a little too big and settles, holds, then floats up growing and fading.
                KeyframeTrack(\.scale) {
                    SpringKeyframe(0.9, duration: 0.15, spring: .snappy)
                    SpringKeyframe(1, duration: 0.15, spring: .bouncy)
                    LinearKeyframe(1, duration: 0.3)
                    CubicKeyframe(1.6, duration: 0.4)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.5)
                    LinearKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.rise) {
                    LinearKeyframe(0, duration: 0.6)
                    CubicKeyframe(-120, duration: 0.4)
                }
            }
            .onAppear { isShown = true }
    }
}
