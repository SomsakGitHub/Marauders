//
//  MaraudersThaiUITests.swift
//  MaraudersUITests
//

import XCTest

/// The app launched in Thai.
///
/// The other UI tests launch the app in English and find tabs and rows by their English labels. Here a tab is found by
/// its position and everything else by its accessibility identifier, and a text is checked for being Thai, not for
/// its wording, so a better translation breaks nothing.
final class MaraudersThaiUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTheFirstFourTabsAreThai() throws {
        let app = launchInThai()

        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs.element(boundBy: 0).waitForExistence(timeout: 15), app.debugDescription)
        for index in 0..<4 {
            let label = tabs.element(boundBy: index).label
            XCTAssertTrue(label.hasThaiCharacter, "tab \(index) reads \"\(label)\"")
        }
    }

    @MainActor
    func testSettingsShowsTheAppLanguageRowInThai() throws {
        let app = launchInThai()
        openSettings(app)

        let row = app.buttons["settings.appLanguage"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        let shown = "\(row.label) \(row.value as? String ?? "")"
        // The value is the language's own name; what is left is the row's title.
        XCTAssertTrue(shown.contains("ไทย"), shown)
        XCTAssertTrue(shown.replacingOccurrences(of: "ไทย", with: "").hasThaiCharacter, shown)
        XCTAssertFalse(shown.contains("App language"), shown)
    }

    /// The gate's message is made in a view model, as a `String`: SwiftUI shows such a text as it is, so it is Thai
    /// only because the view model localizes it.
    @MainActor
    func testASignInMessageComposedInAViewModelIsThai() throws {
        let app = launchInThai(extraArguments: ["UITEST_STREAMING_FEED", "UITEST_GUEST", "UITEST_LOCATION_DENIED"])
        let chooseAudio = app.buttons["feed.chooseAudio"]
        XCTAssertTrue(chooseAudio.waitForExistence(timeout: 15), app.debugDescription)
        chooseAudio.tap()

        let message = app.staticTexts["signin.locationMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(message.label.hasThaiCharacter, message.label)
        XCTAssertFalse(message.label.contains("Set location access"), message.label)
    }

    @MainActor
    func testThaiHoldsAtTheLargestTextSize() throws {
        let app = launchInThai(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        openSettings(app)

        let row = app.buttons["settings.appLanguage"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        var swipes = 0
        while !row.isHittable, swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        XCTAssertTrue(row.label.hasThaiCharacter, row.label)
    }

    // MARK: - Helpers

    @MainActor
    private func launchInThai(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST", "-AppleLanguages", "(th)", "-AppleLocale", "th_TH"] + extraArguments
        app.launchEnvironment["UITEST"] = "1"
        app.launch()
        return app
    }

    /// Settings is the fifth tab. A Debug build adds the Log tab, so its tab bar shows four tabs and More, and
    /// Settings is the first row under More.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let fifthTab = app.tabBars.buttons.element(boundBy: 4)
        XCTAssertTrue(fifthTab.waitForExistence(timeout: 15), app.debugDescription)
        fifthTab.tap()
        let root = app.descendants(matching: .any)["settings.root"]
        if !root.waitForExistence(timeout: 2) {
            app.cells.firstMatch.tap()
        }
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)
    }
}

extension String {
    fileprivate var hasThaiCharacter: Bool {
        unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }
}
