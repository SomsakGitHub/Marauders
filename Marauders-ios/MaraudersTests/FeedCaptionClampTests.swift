//
//  FeedCaptionClampTests.swift
//  Marauders
//

import CoreGraphics
import Testing

@testable import Marauders

/// The feed's caption shows three lines (two at accessibility text sizes) and a "more" button only when the text is
/// really longer than that. These are the rules the view reads its measurements through.
@MainActor
struct FeedCaptionClampTests {
    @Test func lineLimitIsThreeAtNormalSizesAndTwoAtAccessibilitySizes() {
        #expect(FeedCaptionClamp.lineLimit(accessibilitySize: false) == 3)
        #expect(FeedCaptionClamp.lineLimit(accessibilitySize: true) == 2)
    }

    /// A caption that is exactly as tall as its limit shows no "more": nothing is hidden.
    @Test func aCaptionThatFitsIsNeverCut() {
        #expect(FeedCaptionClamp.isCut(fullHeight: 51, clampedHeight: 51) == false)
    }

    /// Two measurements of the same text can differ by a fraction of a point (the hidden copy is laid out on its own);
    /// that is not a hidden line, so up to one point of difference is not a cut.
    @Test func roundingNoiseIsNotACut() {
        #expect(FeedCaptionClamp.isCut(fullHeight: 51.4, clampedHeight: 51) == false)
        #expect(FeedCaptionClamp.isCut(fullHeight: 52, clampedHeight: 51) == false)
    }

    /// A whole extra line (about 17 points of `.subheadline`) is far past the tolerance.
    @Test func moreThanOnePointTallerIsCut() {
        #expect(FeedCaptionClamp.isCut(fullHeight: 71, clampedHeight: 51) == true)
        #expect(FeedCaptionClamp.isCut(fullHeight: 52.5, clampedHeight: 51) == true)
    }
}
