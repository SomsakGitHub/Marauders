import Foundation
import Testing

@testable import Marauders

/// The links the Worker's `config.test.ts` and this file agree on (the plan's "URL cases"): an update link is official
/// only when it is `https` on apple.com or one of its subdomains, with no credentials and no port.
private let officialLinks = [
    "https://apps.apple.com/app/id1234567890", "https://testflight.apple.com/join/AbC123", "https://apple.com/",
    "HTTPS://Apps.Apple.COM/x",
]

private let notOfficialLinks = [
    "http://apps.apple.com/app/id1", "https://example.com/app", "https://evilapple.com/",
    "https://apple.com.evil.example/", "https://apple.com@evil.example/", "https://user:pw@apps.apple.com/",
    "https://apps.apple.com:8443/app", "itms-apps://apps.apple.com/app/id1", "javascript:alert(1)",
]

private let appStoreLink = URL(string: "https://apps.apple.com/app/id1234567890")!

/// The rule that says when this build must stop and send the viewer to update (docs/adr/012-force-update.md). It fails
/// open on everything it cannot be sure of, and it never offers a link off Apple's domains (RF4).
@MainActor
struct UpdateDecisionTests {
    private func config(minimum: Int, link: URL? = appStoreLink) -> AppConfig {
        AppConfig(minimumBuild: minimum, updateURL: link)
    }

    // MARK: The build against the minimum

    @Test(arguments: [(9, 10, true), (10, 10, false), (11, 10, false), (1, 5, true), (1, 1, false)])
    func onlyABuildBelowTheMinimumMustUpdate(build: Int, minimum: Int, mustUpdate: Bool) {
        let expected: UpdateDecision = mustUpdate ? .required(updateURL: appStoreLink) : .allowed
        let decision = UpdateDecision.decide(config: config(minimum: minimum), currentBuild: build, isDebugBuild: false)
        #expect(decision == expected)
    }

    /// Every local build is build 1 (Jenkins numbers the others), and build 1 is stopped like any other: a Run of the
    /// Production scheme on a device shows the screen without a change to the build number (owner, 2026-11-22).
    @Test func aBuildNumberedOneIsStoppedLikeAnyOther() {
        let decision = UpdateDecision.decide(config: config(minimum: 99), currentBuild: 1, isDebugBuild: false)
        #expect(decision == .required(updateURL: appStoreLink))
    }

    /// The one build that is exempt by its kind: a Run of the Staging scheme, build 1 included, is never stopped.
    @Test(arguments: [9, 1])
    func aDebugBuildIsNeverStopped(build: Int) {
        let decision = UpdateDecision.decide(config: config(minimum: 10), currentBuild: build, isDebugBuild: true)
        #expect(decision == .allowed)
    }

    @Test func aBuildWithoutANumberIsNeverStopped() {
        let decision = UpdateDecision.decide(config: config(minimum: 10), currentBuild: nil, isDebugBuild: false)
        #expect(decision == .allowed)
    }

    // MARK: What the Worker said

    @Test func noConfigIsNoGate() {
        #expect(UpdateDecision.decide(config: nil, currentBuild: 9, isDebugBuild: false) == .allowed)
    }

    @Test(arguments: [0, -1])
    func aMinimumOfZeroOrLessIsNoGate(minimum: Int) {
        let decision = UpdateDecision.decide(config: config(minimum: minimum), currentBuild: 9, isDebugBuild: false)
        #expect(decision == .allowed)
    }

    /// The rule is its own check, not only a side effect of the comparison: a minimum of 0 or less is no gate
    /// whatever the build is (a negative build cannot come from a real Info.plist, which is why it is only here).
    @Test func aMinimumOfZeroOrLessIsNoGateWhateverTheBuild() {
        let decision = UpdateDecision.decide(config: config(minimum: -1), currentBuild: -5, isDebugBuild: false)
        #expect(decision == .allowed)
    }

    @Test func aMinimumWithoutALinkIsNoGate() {
        let decision = UpdateDecision.decide(
            config: config(minimum: 10, link: nil), currentBuild: 9, isDebugBuild: false)
        #expect(decision == .allowed)
    }

    /// RF4: a lookalike, credentialed or insecure link never becomes a button, even from a minimum that says stop.
    @Test(arguments: notOfficialLinks)
    func aLinkOffAppleIsNoGate(text: String) throws {
        let link = try #require(URL(string: text))
        let decision = UpdateDecision.decide(
            config: config(minimum: 10, link: link), currentBuild: 9, isDebugBuild: false)
        #expect(decision == .allowed, "never a button to \(text)")
    }

    @Test(arguments: officialLinks)
    func theScreenCarriesTheLinkOfTheConfig(text: String) throws {
        let link = try #require(URL(string: text))
        let decision = UpdateDecision.decide(
            config: config(minimum: 10, link: link), currentBuild: 9, isDebugBuild: false)
        #expect(decision == .required(updateURL: link))
    }

    // MARK: The link rule on its own

    @Test(arguments: officialLinks)
    func everyOfficialLinkIsOfficial(text: String) throws {
        let link = try #require(URL(string: text))
        #expect(UpdateDecision.isOfficialUpdateURL(link))
    }

    @Test(arguments: notOfficialLinks)
    func everyOtherLinkIsNotOfficial(text: String) throws {
        let link = try #require(URL(string: text))
        #expect(!UpdateDecision.isOfficialUpdateURL(link))
    }
}
