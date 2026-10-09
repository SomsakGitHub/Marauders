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
    func testSmokeCanOpenUploadTab() throws {
        let app = launchApp()

        let uploadTab = app.tabBars.buttons["Upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 15))
        uploadTab.tap()

        XCTAssertTrue(app.navigationBars["Upload"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["upload.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["upload.pickVideo"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSmokeEmptyFeedShowsErrorState() throws {
        let app = launchApp(extraArguments: ["UITEST_EMPTY_FEED"])

        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["feed.root"].waitForExistence(timeout: 10))

        let emptyFeedBanner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Feed is empty")
        ).firstMatch
        XCTAssertTrue(emptyFeedBanner.waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST"] + extraArguments

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
