//
//  FeedTapSequence.swift
//  Marauders
//

import Foundation

/// Tells the tap that pauses a clip from the taps that like it, as on TikTok: a second tap soon after the first likes
/// the clip instead of pausing it, and while the hearts keep coming every further quick tap adds one more.
struct FeedTapSequence {
    /// How long a tap waits for a second one before it pauses or plays the clip.
    static let doubleTapInterval: TimeInterval = 0.3
    /// How long after a heart one more tap still adds a heart.
    static let heartRunInterval: TimeInterval = 0.6

    enum Outcome: Equatable {
        /// Pause or play the clip, unless another tap comes within `doubleTapInterval`.
        case waitForSecondTap
        /// Like the clip and show a heart where the finger was.
        case heart
    }

    private var lastTap: TimeInterval?
    private var heartsUntil: TimeInterval?

    /// What a tap at `time` (seconds on a clock that only goes forward) does.
    mutating func tap(at time: TimeInterval) -> Outcome {
        defer { lastTap = time }
        let isSecondTap = lastTap.map { time - $0 < Self.doubleTapInterval } ?? false
        let isInHeartRun = heartsUntil.map { time < $0 } ?? false
        guard isSecondTap || isInHeartRun else { return .waitForSecondTap }
        heartsUntil = time + Self.heartRunInterval
        return .heart
    }
}
