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
        XCTAssertFalse(unavailable.exists)
        app.buttons["clip.closeVideo"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
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
