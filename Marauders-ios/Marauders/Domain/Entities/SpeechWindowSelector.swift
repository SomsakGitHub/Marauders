//
//  SpeechWindowSelector.swift
//  Marauders
//

import Foundation

/// Chooses which stretches of a clip the language check listens to.
///
/// A clip often opens with music, a pause or noise, so its first seconds say little about the language.
/// The selector scores every window by how many of its seconds are loud enough to be speech and picks the
/// best ones. A clip whose opening already sounds like speech keeps its opening, so the check behaves
/// as before wherever it worked. Loudness cannot tell speech from music: the selector only avoids silence,
/// hiss and pauses.
nonisolated enum SpeechWindowSelector {
    /// Seconds in one window; it is also the unit the loudness is measured in.
    static let windowSeconds = 20

    /// A window needs at least this many speech seconds to be worth asking about.
    static let minimumSpeechSeconds = 3

    /// A second window (the stretch before or after the first) shorter than this is not asked about.
    static let shortestExtraSeconds = 5

    /// A later window replaces a speech-bearing opening only when it holds at least this many more speech seconds.
    static let requiredGain = 3

    /// Loudness (root mean square, 0 to 1) below which a second is silence or a hiss, whatever the clip's level.
    static let absoluteFloor = 0.005

    /// A second counts as speech when it reaches this share of the clip's loud level (its 90th percentile).
    /// Low on purpose: quiet talking under a loud bed should still count, and silence is told apart by the floor.
    static let relativeThreshold = 0.1

    /// The windows to listen to, as second ranges of `loudness` (one root-mean-square value per whole second),
    /// the best one first. A second window is the best stretch that does not overlap the first and is at least
    /// `shortestExtraSeconds` long, so a clip a little longer than one window still gets two. A clip no longer
    /// than one window is listened to whole.
    static func windows(loudness: [Double], count: Int) -> [Range<Int>] {
        guard count > 0, !loudness.isEmpty else { return [] }
        guard loudness.count > windowSeconds else { return [0 ..< loudness.count] }

        let speech = speechSeconds(in: loudness)
        var prefix = [0]
        for flag in speech { prefix.append(prefix[prefix.count - 1] + flag) }
        func score(_ range: Range<Int>) -> Int { prefix[range.upperBound] - prefix[range.lowerBound] }

        let fullStarts = loudness.count - windowSeconds + 1
        let fullWindows = (0 ..< fullStarts).map { $0 ..< $0 + windowSeconds }
        let opening = fullWindows[0]
        var first = opening
        if let best = bestRange(in: fullWindows, score: score) {
            // An opening with speech in it is kept unless a later window is clearly better; one without any is not worth keeping.
            let gain = score(opening) < minimumSpeechSeconds ? 1 : requiredGain
            if score(best) >= score(opening) + gain { first = best }
        }
        var result = [first]

        if count > 1 {
            var candidates = fullWindows.filter { $0.upperBound <= first.lowerBound || $0.lowerBound >= first.upperBound }
            // What is left on either side may be shorter than a window; the old behaviour listened to such a tail too.
            let head = max(0, first.lowerBound - windowSeconds) ..< first.lowerBound
            let tail = first.upperBound ..< min(loudness.count, first.upperBound + windowSeconds)
            candidates += [head, tail].filter { $0.count >= shortestExtraSeconds && $0.count < windowSeconds }
            if let second = bestRange(in: candidates, score: score), score(second) >= minimumSpeechSeconds {
                result.append(second)
            }
        }
        return result
    }

    /// 1 for each second that sounds like speech, else 0.
    static func speechSeconds(in loudness: [Double]) -> [Int] {
        let sorted = loudness.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let threshold = max(absoluteFloor, loud * relativeThreshold)
        return loudness.map { $0 >= threshold ? 1 : 0 }
    }

    /// The range with the top score; the earliest wins a tie.
    private static func bestRange(in ranges: [Range<Int>], score: (Range<Int>) -> Int) -> Range<Int>? {
        var best: Range<Int>?
        for range in ranges where best == nil || score(range) > score(best!) { best = range }
        return best
    }
}
