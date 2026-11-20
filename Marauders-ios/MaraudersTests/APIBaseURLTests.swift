import Foundation
import Testing

@testable import Marauders

/// Which Worker the app talks to: the value the build put into Info.plist (`MARAUDERS_API_BASE_URL`, production's URL in
/// a Release build and, while there is one backend, in a Debug build too) or, in a Debug build only, an environment
/// variable of the same name that overrides it. The rules sit in a pure function, so each case runs without a bundle or
/// a process environment.
@MainActor
struct APIBaseURLTests {
    private let environmentKey = APIBaseURL.configKey

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test func theConfiguredValueIsUsedWithoutAnOverride() throws {
        let base = try APIBaseURL.resolve(configured: "https://a.example", override: nil)
        #expect(base == APIBaseURL(url: url("https://a.example"), source: .configured))
    }

    @Test func anOverrideWinsAndIsMarkedAsOne() throws {
        let base = try APIBaseURL.resolve(configured: "https://a.example", override: "https://b.example")
        #expect(base == APIBaseURL(url: url("https://b.example"), source: .override))
    }

    /// An empty variable is what an unticked or blank row of a scheme's environment list gives: no override at all.
    @Test(arguments: ["", "   ", "\n"])
    func anEmptyOverrideCountsAsNone(override: String) throws {
        let base = try APIBaseURL.resolve(configured: "https://a.example", override: override)
        #expect(base == APIBaseURL(url: url("https://a.example"), source: .configured))
    }

    /// A mistyped override must stop the app. Falling back to the configured Worker would send the run to a different
    /// environment than the person asked for, with no sign of it.
    @Test func anInvalidOverrideThrowsInsteadOfFallingBack() {
        #expect(throws: APIConfigurationError.invalidBaseURL) {
            try APIBaseURL.resolve(configured: "https://a.example", override: "http://b.example")
        }
    }

    @Test func onlyHttpsWithoutAPathIsAccepted() throws {
        for rejected in ["http://a.example", "https://a.example/v1", "ftp://a.example", "a.example", "https://"] {
            #expect(throws: APIConfigurationError.invalidBaseURL, "\(rejected) must be refused") {
                try APIBaseURL.resolve(configured: rejected, override: nil)
            }
        }
        for accepted in ["https://a.example", "https://a.example/", "  https://a.example\n"] {
            let base = try APIBaseURL.resolve(configured: accepted, override: nil)
            #expect(base.url.host == "a.example", "\(accepted) must be accepted")
            #expect(base.source == .configured)
        }
    }

    @Test func aMissingValueIsReported() {
        for missing in [nil, "", "   "] as [String?] {
            #expect(throws: APIConfigurationError.missingBaseURL, "\(String(describing: missing)) is no value") {
                try APIBaseURL.resolve(configured: missing, override: nil)
            }
        }
        // An empty override is no override, so it does not stand in for a value the build did not provide.
        #expect(throws: APIConfigurationError.missingBaseURL) {
            try APIBaseURL.resolve(configured: nil, override: "")
        }
    }

    @Test func summaryNamesHostAndSource() {
        let configured = APIBaseURL(url: url("https://a.example"), source: .configured)
        let overridden = APIBaseURL(url: url("https://b.example/"), source: .override)
        #expect(configured.summary == "a.example (configured)")
        #expect(overridden.summary == "b.example (override)")
    }

    #if DEBUG
        @Test func theEnvironmentVariableOverridesTheInfoPlistValueInADebugBuild() throws {
            let base = try APIBaseURL.resolved(
                configured: "https://a.example", environment: [environmentKey: "https://b.example"])
            #expect(base == APIBaseURL(url: url("https://b.example"), source: .override))
        }

        @Test func aVariableWithAnotherNameChangesNothing() throws {
            let base = try APIBaseURL.resolved(
                configured: "https://a.example", environment: ["MARAUDERS_OTHER_URL": "https://b.example"])
            #expect(base == APIBaseURL(url: url("https://a.example"), source: .configured))
        }

        /// The Debug build is made for production while there is one backend (ADR 010): Xcode puts the build setting
        /// into Info.plist, and the app reads it there. Skipped when the process itself carries an override (a scheme
        /// with the variable set).
        @Test(.enabled(if: ProcessInfo.processInfo.environment["MARAUDERS_API_BASE_URL"] == nil))
        func theDebugBuildReceivesProductionThroughInfoPlist() throws {
            let base = try APIBaseURL.resolved()
            #expect(base.source == .configured)
            #expect(base.url.host == "marauders-api.js6ctz7gtj.workers.dev")
        }
    #endif
}
