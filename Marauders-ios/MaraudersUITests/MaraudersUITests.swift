//
//  MaraudersUITests.swift
//  Marauders
//

import XCTest

final class MaraudersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSmokeFeedTabVisibleWithMockData() throws {
        let app = launchApp()

        let feedTab = app.tabBars.buttons["Feed"]
        XCTAssertTrue(feedTab.waitForExistence(timeout: 15))
        XCTAssertTrue(feedTab.isSelected)

        XCTAssertTrue(app.otherElements["feed.root"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSmokeCanOpenMapTab() throws {
        let app = launchApp()

        let mapTab = app.tabBars.buttons["Map"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 15))
        mapTab.tap()

        XCTAssertTrue(app.descendants(matching: .any)["map.root"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testPlaceSearchShowsChoicesAndConfirmsSelectedPin() throws {
        let app = launchApp()
        app.tabBars.buttons["Upload"].tap()
        let choose = app.buttons["upload.chooseClipLocation"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let field = app.textFields["upload.clipLocationPicker.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("CentralWorld Bangkok")
        let results = app.descendants(matching: .any)["upload.clipLocationPicker.results"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 25), app.debugDescription)
        let first = results.buttons.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertFalse(results.exists)
        app.buttons["upload.clipLocationPicker.confirm"].tap()
        XCTAssertTrue(app.staticTexts["upload.clipLocation.value"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSmokeUploadTab() throws {
        let app = launchApp()

        let uploadTab = app.tabBars.buttons["Upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 15))
        uploadTab.tap()

        XCTAssertTrue(app.navigationBars["Upload"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["upload.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["upload.pickVideo"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSmokeProfileTab() throws {
        let app = launchApp()

        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        XCTAssertTrue(app.descendants(matching: .any)["profile.root"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["profile.signOut"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testProfileCanDeleteOwnClip() throws {
        let app = launchApp()

        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        let clip = app.buttons["profile.clip"]
        XCTAssertTrue(clip.waitForExistence(timeout: 15))
        clip.tap()

        if app.buttons["Original audio"].waitForExistence(timeout: 5) { app.buttons["Original audio"].tap() }

        let deleteButton = app.buttons["clip.delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.tap()

        let confirmDelete = app.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10))
        confirmDelete.tap()

        let emptyState = app.staticTexts["No clips yet"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSmokeEmptyFeedShowsEmptyState() throws {
        let app = launchApp(extraArguments: ["UITEST_EMPTY_FEED"])

        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["feed.root"].waitForExistence(timeout: 10))

        let emptyFeedBanner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "No clips to show yet")
        ).firstMatch
        XCTAssertTrue(emptyFeedBanner.waitForExistence(timeout: 15))
    }

    @MainActor
    func testFeedAvatarOpensPublicProfile() throws {
        let app = launchApp()

        XCTAssertTrue(app.otherElements["feed.root"].waitForExistence(timeout: 15))

        let avatar = app.buttons["feed.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["publicProfile.root"].waitForExistence(timeout: 15)
        )
    }

    @MainActor
    func testMapClipAuthorOpensPublicProfile() throws {
        let app = launchApp()

        let mapTab = app.tabBars.buttons["Map"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 15))
        mapTab.tap()

        let pin = app.buttons["map.clipPin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        pin.tap()

        // The player may offer an audio choice on open; it covers the author bar.
        let author = app.buttons["clip.author"]
        XCTAssertTrue(author.waitForExistence(timeout: 15))
        let originalAudio = app.buttons["Original audio"]
        if originalAudio.waitForExistence(timeout: 3) {
            originalAudio.tap()
        }
        XCTAssertTrue(author.isHittable)
        let authorHandle = author.label
        author.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["publicProfile.root"].waitForExistence(timeout: 15)
        )
        let shownHandle = app.staticTexts["publicProfile.handle"]
        XCTAssertTrue(shownHandle.waitForExistence(timeout: 10))
        XCTAssertEqual(shownHandle.label, authorHandle)
    }

    @MainActor
    func testProfileShowsChangeAvatarControl() throws {
        let app = launchApp()

        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        XCTAssertTrue(app.descendants(matching: .any)["profile.root"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["profile.avatar"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testStreamingFeedForwardAndReverseSwipes() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED"])
        let feed = app.otherElements["feed.root"]
        XCTAssertTrue(feed.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 10))
        attachFeedScreenshot(app, name: "initial")
        for iteration in 0..<3 {
            feed.swipeUp(velocity: .fast)
            XCTAssertTrue(app.staticTexts["Streaming test clip 1"].waitForExistence(timeout: 10))
            attachFeedScreenshot(app, name: "forward-\(iteration)")
            feed.swipeDown(velocity: .fast)
            XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 10))
            attachFeedScreenshot(app, name: "reverse-\(iteration)")
        }
        XCTAssertFalse(app.buttons["Play Again"].exists)
    }

    @MainActor
    func testStreamingShortDragsReturnToSameClipInBothDirections() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED"])
        let feed = app.otherElements["feed.root"]
        XCTAssertTrue(feed.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 10))
        let middle = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.1,
                     thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)),
                     withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 10))
        feed.swipeUp(velocity: .fast)
        XCTAssertTrue(app.staticTexts["Streaming test clip 1"].waitForExistence(timeout: 10))
        middle.press(forDuration: 0.1,
                     thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)),
                     withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.staticTexts["Streaming test clip 1"].waitForExistence(timeout: 10))
        feed.swipeDown(velocity: .fast)
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Play Again"].exists)
    }

    @MainActor
    func testGuestFeedAudioChoiceRequiresSignIn() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED", "UITEST_GUEST"])
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].waitForExistence(timeout: 15))
        let choose = app.buttons["feed.chooseAudio"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        XCTAssertTrue(app.buttons["auth.closeSignIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["clip.chooseAudio"].exists)
        app.buttons["auth.closeSignIn"].tap()
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        app.buttons["auth.completeUITestSignIn"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)
        XCTAssertFalse(app.buttons["auth.closeSignIn"].exists)
        XCTAssertFalse(app.buttons["clip.chooseAudio"].exists)
        XCTAssertFalse(app.buttons["clip.closeVideo"].exists)
        XCTAssertFalse(app.buttons["Listen in Thai (AI)"].exists)
        XCTAssertTrue(app.staticTexts["Streaming test clip 0"].exists)

    }

    @MainActor
    func testSignInDetectedCountryCanBeChanged() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED", "UITEST_GUEST"])
        let choose = app.buttons["feed.chooseAudio"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()
        let country = app.buttons["signin.country"]
        XCTAssertTrue(country.waitForExistence(timeout: 5))
        XCTAssertTrue(country.label.contains("🇹🇭"))
        country.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("United States")
        let usa = app.buttons["country.US"]
        XCTAssertTrue(usa.waitForExistence(timeout: 5))
        usa.tap()
        XCTAssertTrue(country.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(country.label.contains("🇺🇸"))
        XCTAssertTrue(app.buttons["signin.apple"].isEnabled)
        app.buttons["auth.closeSignIn"].tap()
    }

    @MainActor
    func testSignInRequiresLocationPermission() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED", "UITEST_GUEST", "UITEST_LOCATION_DENIED"])
        let choose = app.buttons["feed.chooseAudio"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()
        let apple = app.buttons["signin.apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5))
        XCTAssertFalse(apple.isEnabled)
        XCTAssertFalse(app.buttons["auth.completeUITestSignIn"].isEnabled)
        XCTAssertTrue(app.buttons["signin.allowLocation"].exists)
        app.buttons["auth.closeSignIn"].tap()
    }

    @MainActor
    func testTabsUseSharedSignInAndCancelReturnsToSource() throws {
        let app = launchApp(extraArguments: ["UITEST_GUEST"])
        for tab in ["Map", "Profile", "Upload"] {
            app.tabBars.buttons[tab].tap()
            let open = app.buttons["auth.openSignIn"]
            XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
            open.tap()
            let close = app.buttons["auth.closeSignIn"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["signin.country"].exists)
            close.tap()
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected)
            XCTAssertTrue(open.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testAIAudioRequiresViewerChoiceAndHandlesUnavailableService() throws {
        let app = launchApp(extraArguments: ["UITEST_STREAMING_FEED"])
        let choose = app.buttons["feed.chooseAudio"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20))
        choose.tap()
        app.buttons["Original audio"].tap()
        XCTAssertFalse(app.buttons["clip.chooseAudio"].exists)
        choose.tap()
        app.buttons["Listen in Thai (AI)"].tap()
        let unavailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "isn't ready to translate")).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
        attachFeedScreenshot(app, name: "ai-audio-unavailable-original-remains")
        app.buttons["clip.chooseAudio"].tap()
        app.buttons["Original audio"].tap()
        // The notice goes once the view model has cleared it and SwiftUI has redrawn, a moment after the tap returns.
        XCTAssertTrue(waitUntilGone(unavailable), app.debugDescription)
        app.buttons["clip.closeVideo"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
    }

    @MainActor
    func testFeedCommentsCanBeReadPostedAndDeleted() throws {
        let app = launchApp()
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()

        XCTAssertTrue(app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(commentRow(app, containing: "UI test comment from me").waitForExistence(timeout: 10), app.debugDescription)
        let friendsRow = commentRow(app, containing: "UI test comment from a friend")
        XCTAssertTrue(friendsRow.exists)
        attachFeedScreenshot(app, name: "comments-sheet")

        // Delete is offered on the viewer's own comments and on the ones under the viewer's clip, not on a friend's.
        friendsRow.swipeLeft()
        XCTAssertFalse(deleteAction(app).waitForExistence(timeout: 1), app.debugDescription)

        let input = app.descendants(matching: .any)["comments.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let send = app.buttons["comments.send"]
        XCTAssertFalse(send.isEnabled)
        input.tap()
        input.typeText("Great clip!")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let posted = commentRow(app, containing: "Great clip!")
        XCTAssertTrue(posted.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(send.isEnabled)

        posted.swipeLeft()
        let delete = deleteAction(app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()
        // A confirmation dialog button shows up twice in the tree (the button and the label inside it).
        let confirm = app.buttons["comments.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(waitUntilGone(posted), app.debugDescription)
        XCTAssertTrue(commentRow(app, containing: "UI test comment from me").exists)

        app.buttons["comments.close"].firstMatch.tap()
        XCTAssertTrue(waitUntilGone(app.descendants(matching: .any)["comments.root"]))
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    func testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn() throws {
        let app = launchApp()
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 10))

        let input = app.descendants(matching: .any)["comments.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Este lugar es increíble, volveremos pronto")
        app.buttons["comments.send"].tap()
        XCTAssertTrue(commentRow(app, containing: "Este lugar es").waitForExistence(timeout: 10), app.debugDescription)
        // The UI-test viewer is in the US, so the Spanish comment gives the page its Show originals switch, while
        // the English comments seeded for the clip alone did not. No comment has a button of its own.
        XCTAssertTrue(app.buttons["comments.pageTranslation"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "comments.translate").count, 0, app.debugDescription)
    }

    @MainActor
    func testSwipingTheCommentsSheetDownClosesItAndItOpensAgain() throws {
        let app = launchApp()
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let root = app.descendants(matching: .any)["comments.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10))

        // Dragging the sheet down by its title closes it the way the close button does.
        dragCommentsSheetDown(app)
        XCTAssertTrue(waitUntilGone(root), app.debugDescription)
        XCTAssertTrue(open.waitForExistence(timeout: 5))

        open.tap()
        XCTAssertTrue(root.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testSwipingTheCommentsSheetDownClosesItWhileTheKeyboardIsUp() throws {
        let app = launchApp()
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let root = app.descendants(matching: .any)["comments.root"]
        let input = app.descendants(matching: .any)["comments.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()

        // The control for the draft test below: the same sheet, the same keyboard and the same drags, nothing typed.
        // Without it, that test could pass because the drag was too weak and not because the draft held the sheet.
        XCTAssertTrue(swipeCommentsSheetAway(app, root: root), app.debugDescription)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAHalfTypedCommentSurvivesASwipeDown() throws {
        let app = launchApp()
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let root = app.descendants(matching: .any)["comments.root"]
        let input = app.descendants(matching: .any)["comments.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Not sent yet")

        // The same drags that close the sheet in the test above.
        XCTAssertFalse(swipeCommentsSheetAway(app, root: root), "the sheet should stay open while a draft is typed")

        // A stray swipe keeps the sheet and the draft; the close button still discards both.
        XCTAssertEqual(input.value as? String, "Not sent yet")
        app.buttons["comments.close"].firstMatch.tap()
        XCTAssertTrue(waitUntilGone(root), app.debugDescription)
    }

    @MainActor
    func testGuestCanReadCommentsButMustSignInToWrite() throws {
        let app = launchApp(extraArguments: ["UITEST_GUEST"])
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()

        XCTAssertTrue(commentRow(app, containing: "UI test comment from a friend").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["comments.input"].exists)
        let signIn = app.buttons["comments.signIn"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()

        // The comments sheet gives way to the shared sign-in screen; closing it returns to the feed.
        XCTAssertTrue(app.buttons["auth.closeSignIn"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["comments.root"].exists)
        app.buttons["auth.closeSignIn"].tap()
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)
        // The feed's own button stays in the tree under a sheet, so only the sheet's root says it did not come back.
        XCTAssertFalse(app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 2), "the sheet must stay closed")
        XCTAssertTrue(open.waitForExistence(timeout: 5))

        // Once signed in, the same sheet offers the composer instead of the sign-in button.
        open.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        let complete = app.buttons["auth.completeUITestSignIn"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10), app.debugDescription)
        complete.tap()
        // The feed behind the closing sign-in sheet also has the button; wait for the sheet to be gone first.
        XCTAssertTrue(waitUntilGone(app.buttons["auth.closeSignIn"]), app.debugDescription)
        // Signing in leaves the viewer on the feed, not back in the sheet that sent them to sign in.
        XCTAssertFalse(app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 2), "the sheet must stay closed")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["comments.input"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["comments.signIn"].exists)
    }

    @MainActor
    func testTheClipStaysPausedBehindSignInFromCommentsAndPlaysAgainWhenViewerBacksOut() throws {
        let app = launchApp(extraArguments: ["UITEST_GUEST"])
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        // The paused glyph is the only sign of the player's state the screen gives.
        let paused = app.descendants(matching: .any)["feed.pausedIndicator"]
        let closeSignIn = app.buttons["auth.closeSignIn"]

        open.tap()
        let signIn = app.buttons["comments.signIn"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), app.debugDescription)
        signIn.tap()
        XCTAssertTrue(closeSignIn.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(paused.waitForExistence(timeout: 5), "the clip should be paused while the viewer signs in")

        // A system alert or the Apple sign-in sheet takes the app through the background and back, which asks the feed
        // to start playing again.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(closeSignIn.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(waitUntilGone(paused, timeout: 3), "the clip must not start behind the sign-in screen")

        closeSignIn.tap()
        XCTAssertTrue(waitUntilGone(paused), "the clip should play again once the viewer backs out of signing in")
    }

    /// `UITEST_REJECTED_SESSION`: the viewer is signed in, but the Worker answers 401 to every request that carries
    /// their token. The profile is the first to ask; the 401 must sign the viewer out without any screen handling it.
    @MainActor
    func testARejectedSessionSignsTheViewerOutAndTheSharedSignInTakesOver() throws {
        let app = launchApp(extraArguments: ["UITEST_REJECTED_SESSION"])

        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        let gate = app.descendants(matching: .any)["profile.signInRequired"]
        XCTAssertTrue(gate.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["profile.root"].exists)

        // The gate leads to the shared sign-in screen, like it does for a guest.
        let open = app.buttons["auth.openSignIn"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        // The gate appears while the app is still busy with the sign-out, and a tap before the button can be hit lands
        // nowhere.
        XCTAssertTrue(waitUntilHittable(open), app.debugDescription)
        open.tap()
        let close = app.buttons["auth.closeSignIn"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["signin.country"].exists)
        close.tap()
        XCTAssertTrue(app.tabBars.buttons["Profile"].isSelected)
        XCTAssertTrue(open.waitForExistence(timeout: 5))

        // The other tabs that need a session are gated too, and the feed carries on for a guest.
        app.tabBars.buttons["Upload"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["upload.signInRequired"].waitForExistence(timeout: 10), app.debugDescription)
        app.tabBars.buttons["Feed"].tap()
        XCTAssertTrue(app.buttons["feed.comments"].waitForExistence(timeout: 15), app.debugDescription)
    }

    /// The 401 that ends the session arrives as the profile's own load fails. Signing in again must start a new load
    /// instead of landing on the error the old one left behind.
    @MainActor
    func testSigningInAgainAfterARejectedSessionDoesNotLandOnTheOldProfileError() throws {
        let app = launchApp(extraArguments: ["UITEST_REJECTED_SESSION"])
        app.tabBars.buttons["Profile"].tap()

        let open = app.buttons["auth.openSignIn"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitUntilHittable(open), app.debugDescription)
        open.tap()
        let complete = app.buttons["auth.completeUITestSignIn"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10), app.debugDescription)
        complete.tap()

        // The test sign-in stores no token, so the new load fails by itself ("Sign in required"). What matters is that
        // it ran: the 401 of the first one must be gone.
        XCTAssertTrue(app.buttons["profile.retry"].waitForExistence(timeout: 10), app.debugDescription)
        let old401 = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "401")).firstMatch
        XCTAssertFalse(old401.exists, app.debugDescription)
    }

    /// The comments read is the one request that is repeated as a guest after a 401. It must still show the comments,
    /// the sheet must stay open although the 401 signed the viewer out, and the composer gives way to the sign-in button.
    @MainActor
    func testARejectedSessionStillLetsTheViewerReadCommentsAsAGuest() throws {
        let app = launchApp(extraArguments: ["UITEST_REJECTED_SESSION"])
        let open = app.buttons["feed.comments"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()

        let comment = commentRow(app, containing: "UI test comment from a friend")
        XCTAssertTrue(comment.waitForExistence(timeout: 10), app.debugDescription)
        let signIn = app.buttons["comments.signIn"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["comments.input"].exists)

        // Signing out closes nothing: the sheet and its list are still there a moment later.
        XCTAssertTrue(app.descendants(matching: .any)["comments.root"].waitForExistence(timeout: 2))
        XCTAssertTrue(comment.exists)

        // From here on it is the guest flow: the button gives way to the shared sign-in screen.
        signIn.tap()
        XCTAssertTrue(app.buttons["auth.closeSignIn"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["comments.root"].exists)
        app.buttons["auth.closeSignIn"].tap()
        XCTAssertTrue(app.tabBars.buttons["Feed"].isSelected)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    private func commentRow(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "comments.row")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Drags the comments sheet down by its title bar, hard and fast enough to dismiss it, as a thumb would. The
    /// feed's own button is captioned "Comments" too, so the title is looked up inside the sheet's bar; and an
    /// element's own `swipeDown` travels only as far as the element is tall, which for a title is not far.
    @MainActor
    private func dragCommentsSheetDown(_ app: XCUIApplication) {
        let title = app.navigationBars["Comments"].staticTexts["Comments"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Drags the comments sheet down until it closes, twice at most: a sheet open to its large size first settles at the
    /// medium one. True when the sheet is gone.
    @MainActor
    private func swipeCommentsSheetAway(_ app: XCUIApplication, root: XCUIElement) -> Bool {
        for _ in 0..<2 {
            dragCommentsSheetDown(app)
            if waitUntilGone(root, timeout: 3) { return true }
        }
        return false
    }

    /// The Delete action a swiped comment row offers, whether it is found by identifier or by its label.
    @MainActor
    private func deleteAction(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "comments.delete", "Delete")).firstMatch
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor
    private func attachFeedScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // English keeps label lookups stable on devices set to another language.
        app.launchArguments = ["UITEST", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments

        var environment = app.launchEnvironment
        environment["UITEST"] = "1"
        if extraArguments.contains("UITEST_EMPTY_FEED") {
            environment["UITEST_EMPTY_FEED"] = "1"
        }
        app.launchEnvironment = environment

        app.launch()
        return app
    }
}
