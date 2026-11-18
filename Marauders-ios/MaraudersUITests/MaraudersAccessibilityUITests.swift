//
//  MaraudersAccessibilityUITests.swift
//  MaraudersUITests
//

import XCTest

/// Accessibility of the feed at the text sizes people use, and Apple's audit of the main screens.
///
/// The feed's caption and the action rail share one row, so the caption must stay clear of the rail at every text
/// size, and a caption that is cut offers "more". The tests find the caption and the rail by their identifiers and
/// compare frames, so a different wording or a different size breaks nothing.
///
/// The audit tests run `performAccessibilityAudit` for the three kinds that answer the same way every time: an
/// element without a name (`sufficientElementDescription`), without the right role (`trait`), or with a hit area that
/// is too small (`hitRegion`). Contrast, Dynamic Type and clipped text are left out on purpose: in the baseline run 39
/// of the 120 reports were false positives, and controls the system draws fail in them, so a guard on those kinds
/// would be red for no reason. The colours the pass changed are pinned by a unit test (`AvatarPaletteTests`) and the
/// text sizes by the tests above.
final class MaraudersAccessibilityUITests: XCTestCase {
    /// The largest Dynamic Type size: accessibility 5.
    private static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The caption and the rail

    @MainActor
    func testALongCaptionStaysLeftOfTheRail() throws {
        assertTheCaptionIsClearOfTheRail(launch(["UITEST_LONG_CAPTION"]))
    }

    @MainActor
    func testALongCaptionStaysLeftOfTheRailAtTheLargestTextSize() throws {
        assertTheCaptionIsClearOfTheRail(launch(["UITEST_LONG_CAPTION"], textSize: Self.largestText))
    }

    @MainActor
    func testMoreOpensTheWholeCaptionAndLessClosesIt() throws {
        let app = launch(["UITEST_LONG_CAPTION"])
        let feed = app.otherElements["feed.root"]
        let caption = app.staticTexts["feed.caption"]
        let toggle = app.buttons["feed.captionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(toggle.label, "more")
        let closedHeight = caption.frame.height

        toggle.tap()
        XCTAssertTrue(waitUntilLabel(toggle, is: "less"), app.debugDescription)
        let openHeight = caption.frame.height
        XCTAssertGreaterThan(openHeight, closedHeight, "the whole caption is shown")
        XCTAssertLessThanOrEqual(openHeight, feed.frame.height * 0.45, "the opened block stays in the lower part")

        toggle.tap()
        XCTAssertTrue(waitUntilLabel(toggle, is: "more"), app.debugDescription)
        XCTAssertEqual(caption.frame.height, closedHeight, accuracy: 1)
    }

    /// At the largest text size the whole caption is many screens tall. The opened block stops at 40% of the feed and
    /// scrolls inside, so it never reaches the upper part of the screen, and "less" and the rail stay in reach. (At the
    /// default size the caption fits and does not scroll, which the test above covers.)
    @MainActor
    func testAnOpenedCaptionStaysInTheLowerPartAndScrollsAtTheLargestTextSize() throws {
        let app = launch(["UITEST_LONG_CAPTION"], textSize: Self.largestText)
        let feed = app.otherElements["feed.root"]
        let caption = app.staticTexts["feed.caption"]
        let toggle = app.buttons["feed.captionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(toggle.label, "more")

        toggle.tap()
        XCTAssertTrue(waitUntilLabel(toggle, is: "less"), app.debugDescription)

        // The block is a scroll view of its own, with the caption inside; the caption's own frame is the whole text's.
        let block = app.scrollViews.containing(.staticText, identifier: "feed.caption").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 5), "the opened caption does not scroll: \(app.debugDescription)")
        XCTAssertLessThanOrEqual(block.frame.height, feed.frame.height * 0.45, "the opened block grew past its cap")
        XCTAssertGreaterThan(
            block.frame.minY, feed.frame.minY + feed.frame.height * 0.3, "the opened block reaches into the upper part")

        // "less" and the rail are still there to be used.
        XCTAssertTrue(waitUntilHittable(toggle), "less is covered: \(app.debugDescription)")
        XCTAssertTrue(feed.frame.contains(toggle.frame), "less is off the screen: \(toggle.frame)")
        XCTAssertTrue(waitUntilHittable(app.buttons["feed.like"]), "Like is covered: \(app.debugDescription)")

        // A swipe inside the block moves the text; it does not page the feed.
        let before = caption.frame.minY
        block.swipeUp()
        XCTAssertLessThan(caption.frame.minY, before, "the opened caption did not scroll")

        toggle.tap()
        XCTAssertTrue(waitUntilLabel(toggle, is: "more"), app.debugDescription)
    }

    /// A caption that fits has nothing hidden, so it offers nothing to open.
    @MainActor
    func testAShortCaptionHasNoMoreButton() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["feed.caption"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["feed.captionToggle"].waitForExistence(timeout: 2), app.debugDescription)
    }

    /// Captions are optional: without one the rail still sits on the right edge, not on the left of an empty row.
    @MainActor
    func testAClipWithoutACaptionKeepsTheRailOnTheRight() throws {
        let app = launch(["UITEST_NO_CAPTION"])
        let feed = app.otherElements["feed.root"]
        let like = app.buttons["feed.like"]
        XCTAssertTrue(like.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["feed.caption"].exists, "this clip has no caption")

        XCTAssertGreaterThan(like.frame.midX, feed.frame.midX, "the rail slid to the left")
        let railRight = railButtons(app).map { $0.frame.maxX }.max() ?? 0
        XCTAssertGreaterThan(railRight, feed.frame.maxX - 40, "the rail is not on the right edge")
    }

    /// The next clip starts with its caption closed, whatever state the last one was left in.
    @MainActor
    func testAnOpenCaptionClosesWhenTheClipChanges() throws {
        let app = launch(["UITEST_STREAMING_FEED", "UITEST_LONG_CAPTION"])
        let toggle = app.buttons["feed.captionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
        toggle.tap()
        XCTAssertTrue(waitUntilLabel(toggle, is: "less"), app.debugDescription)

        // The clips need not play for the pager to move.
        app.otherElements["feed.root"].swipeUp(velocity: .fast)

        XCTAssertTrue(waitUntilLabel(toggle, is: "more"), "the next clip must start with its caption closed")
    }

    /// The caption ignores touches, so a double tap on it still likes the clip, as on the rest of the clip.
    @MainActor
    func testADoubleTapOverACollapsedCaptionStillLikesTheClip() throws {
        let app = launch(["UITEST_LONG_CAPTION"])
        let like = app.buttons["feed.like"]
        let caption = app.staticTexts["feed.caption"]
        XCTAssertTrue(like.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(caption.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(like.label, "Like")

        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).doubleTap()

        XCTAssertTrue(waitUntilLabel(like, is: "Unlike"), app.debugDescription)
    }

    // MARK: - The rail at large text sizes

    /// The rail is icons with a short label, so it stops growing at the largest size that is not an accessibility size
    /// (as the tab bar does); the large-content viewer, a long press, shows each button at full size.
    @MainActor
    func testTheRailStopsGrowingAtTheLargestNonAccessibilitySize() throws {
        let big = launch(textSize: "UICTContentSizeCategoryXXXL")
        XCTAssertTrue(big.buttons["feed.like"].waitForExistence(timeout: 15), big.debugDescription)
        XCTAssertTrue(big.buttons["feed.comments"].waitForExistence(timeout: 15), big.debugDescription)
        let likeAtXXXL = big.buttons["feed.like"].frame.size
        let commentsAtXXXL = big.buttons["feed.comments"].frame.size
        big.terminate()

        let biggest = launch(textSize: Self.largestText)
        XCTAssertTrue(biggest.buttons["feed.like"].waitForExistence(timeout: 15), biggest.debugDescription)
        XCTAssertTrue(biggest.buttons["feed.comments"].waitForExistence(timeout: 15), biggest.debugDescription)
        let like = biggest.buttons["feed.like"].frame.size
        let comments = biggest.buttons["feed.comments"].frame.size
        XCTAssertEqual(like.width, likeAtXXXL.width, accuracy: 1, "Like grew past the cap")
        XCTAssertEqual(like.height, likeAtXXXL.height, accuracy: 1, "Like grew past the cap")
        XCTAssertEqual(comments.width, commentsAtXXXL.width, accuracy: 1, "Comments grew past the cap")
        XCTAssertEqual(comments.height, commentsAtXXXL.height, accuracy: 1, "Comments grew past the cap")
    }

    /// The fixture clip cannot play, so its failure card is up. The card is under the row of caption and rail: at the
    /// largest text size its plate used to be over Like and Comments.
    @MainActor
    func testLikeAndCommentsStayReachableUnderTheFailureCardAtTheLargestTextSize() throws {
        let app = launch(textSize: Self.largestText)
        let playAgain = app.buttons["Play Again"]
        XCTAssertTrue(playAgain.waitForExistence(timeout: 30), app.debugDescription)
        for identifier in ["feed.like", "feed.comments", "feed.avatar"] {
            XCTAssertTrue(
                waitUntilHittable(app.buttons[identifier]), "\(identifier) is covered: \(app.debugDescription)")
        }
        XCTAssertTrue(waitUntilHittable(playAgain), "Play Again is covered: \(app.debugDescription)")

        // Hittable says where the element is; a tap says it answers. Like flips its label when it takes the tap.
        let like = app.buttons["feed.like"]
        XCTAssertEqual(like.label, "Like")
        like.tap()
        XCTAssertTrue(waitUntilLabel(like, is: "Unlike"), "the tap on Like did not reach it: \(app.debugDescription)")
    }

    // MARK: - The clip player at the largest text size

    /// The map's player has the most buttons: "Play in Feed" sits under "Open in Google Maps". At the largest text size
    /// the bar needs more than the screen has, so it scrolls under the top bar instead of running off the bottom, and
    /// the top bar, with Close, stays where it is.
    @MainActor
    func testEveryButtonOfTheMapsPlayerCanBeReachedAtTheLargestTextSize() throws {
        let app = launch(textSize: Self.largestText)
        let mapTab = app.tabBars.buttons["Map"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 25), app.debugDescription)
        mapTab.tap()
        let pin = app.buttons["map.clipPin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 25), app.debugDescription)
        pin.tap()
        // The player may offer the audio choice as it opens; the dialog covers its buttons.
        let originalAudio = app.buttons["Original audio"]
        if originalAudio.waitForExistence(timeout: 3) { originalAudio.tap() }

        let screen = app.windows.firstMatch.frame
        let close = app.buttons["clip.closeVideo"]
        let playInFeed = app.buttons["clip.playInFeed"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(playInFeed.waitForExistence(timeout: 5), app.debugDescription)

        var swipes = 0
        while !screen.contains(playInFeed.frame) && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(
            screen.contains(playInFeed.frame), "Play in Feed runs off the screen: \(playInFeed.frame) in \(screen)")
        XCTAssertTrue(screen.contains(close.frame), "Close went with the bar: \(close.frame) in \(screen)")

        // On screen is not enough: the tap must reach the button, which closes the player and opens the feed.
        playInFeed.tap()
        let playerGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [playerGone], timeout: 15), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["feed.like"].waitForExistence(timeout: 20), app.debugDescription)
    }

    // MARK: - Apple's audit of the main screens

    // One test per screen, so a failure names the screen that has it.

    @MainActor
    func testTheFeedPassesTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toFeed(app), app.debugDescription)
        try audit(app)
    }

    /// A long caption is cut and offers "more": that button needs a name, a role and a hit area of its own.
    @MainActor
    func testTheFeedWithALongCaptionPassesTheStableAudits() throws {
        let app = launch(["UITEST_LONG_CAPTION"])
        XCTAssertTrue(toFeed(app), app.debugDescription)
        XCTAssertTrue(app.buttons["feed.captionToggle"].waitForExistence(timeout: 10), app.debugDescription)
        try audit(app)
    }

    @MainActor
    func testCommentsPassTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toComments(app), app.debugDescription)
        try audit(app)
    }

    @MainActor
    func testTheMapPassesTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toTab(app, "Map", root: "map.root"), app.debugDescription)
        try audit(app)
    }

    @MainActor
    func testUploadPassesTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toTab(app, "Upload", root: "upload.root"), app.debugDescription)
        try audit(app)
    }

    @MainActor
    func testProfilePassesTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toTab(app, "Profile", root: "profile.root"), app.debugDescription)
        try audit(app)
    }

    @MainActor
    func testSettingsPassesTheStableAudits() throws {
        let app = launch()
        XCTAssertTrue(toSettings(app), app.debugDescription)
        try audit(app)
    }

    /// A guest who likes a clip meets the sign-in sheet.
    @MainActor
    func testTheSignInSheetPassesTheStableAudits() throws {
        let app = launch(["UITEST_GUEST"])
        XCTAssertTrue(toSignInSheet(app), app.debugDescription)
        try audit(app)
    }

    // MARK: - Helpers

    @MainActor
    private func launch(_ flags: [String] = [], textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // English keeps label lookups stable on devices set to another language.
        var arguments = ["UITEST", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = arguments
        app.launchEnvironment["UITEST"] = "1"
        app.launch()
        return app
    }

    /// The buttons of the feed's rail that are on screen for the fixture clip.
    @MainActor
    private func railButtons(_ app: XCUIApplication) -> [XCUIElement] {
        ["feed.like", "feed.comments", "feed.avatar"].map { app.buttons[$0] }.filter { $0.exists }
    }

    @MainActor
    private func assertTheCaptionIsClearOfTheRail(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let caption = app.staticTexts["feed.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        XCTAssertTrue(
            app.buttons["feed.like"].waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        let railLeft = railButtons(app).map { $0.frame.minX }.min() ?? .greatestFiniteMagnitude
        XCTAssertLessThan(caption.frame.maxX, railLeft, "the caption runs under the rail", file: file, line: line)
        // VoiceOver reads all of the caption, although only the first lines of a long one are drawn.
        XCTAssertTrue(caption.label.hasSuffix("The end."), caption.label, file: file, line: line)
    }

    @MainActor
    private func waitUntilLabel(_ element: XCUIElement, is label: String, timeout: TimeInterval = 10) -> Bool {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    // MARK: Audit

    /// Apple's audit of what is on screen, for the three stable kinds. Any report fails the test except the one the
    /// closure answers `true` for: Apple Maps' own "Legal" link, which the audit finds too small and the app does not
    /// draw.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait, .hitRegion]) { issue in
            issue.element?.label == "Legal"
        }
    }

    // MARK: Navigation

    @MainActor
    private func toFeed(_ app: XCUIApplication) -> Bool {
        app.otherElements["feed.root"].waitForExistence(timeout: 25)
            && app.buttons["feed.like"].waitForExistence(timeout: 10)
    }

    @MainActor
    private func toComments(_ app: XCUIApplication) -> Bool {
        guard toFeed(app) else { return false }
        let button = app.buttons["feed.comments"]
        guard button.waitForExistence(timeout: 10) else { return false }
        button.tap()
        return app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 15)
    }

    @MainActor
    private func toTab(_ app: XCUIApplication, _ tab: String, root: String) -> Bool {
        let button = app.tabBars.buttons[tab]
        guard button.waitForExistence(timeout: 25) else { return false }
        button.tap()
        return app.descendants(matching: .any)[root].waitForExistence(timeout: 15)
    }

    /// A guest is asked to sign in when they like a clip.
    @MainActor
    private func toSignInSheet(_ app: XCUIApplication) -> Bool {
        guard toFeed(app) else { return false }
        app.buttons["feed.like"].tap()
        return app.buttons["auth.closeSignIn"].waitForExistence(timeout: 15)
    }

    /// Settings is a tab of its own, or under More when the tab bar has no room for it (Debug builds add Log).
    @MainActor
    private func toSettings(_ app: XCUIApplication) -> Bool {
        let direct = app.tabBars.buttons["Settings"]
        if direct.waitForExistence(timeout: 8) {
            direct.tap()
        } else {
            let more = app.tabBars.buttons["More"]
            guard more.waitForExistence(timeout: 10) else { return false }
            more.tap()
            let row = app.cells.staticTexts["Settings"].firstMatch
            if row.waitForExistence(timeout: 8) { row.tap() }
        }
        return app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 15)
    }
}
