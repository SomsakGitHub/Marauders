//
//  DebugSessionFaultTests.swift
//  MaraudersTests
//

#if DEBUG
    import Foundation
    import Testing

    @testable import Marauders

    /// The Debug-only launch argument that lets a real session meet a rejected access token on a phone: it swaps the
    /// stored token for one that cannot pass for a live one, and does nothing at all without the argument.
    @MainActor
    struct DebugSessionFaultTests {
        /// The one name the docs and the check on the phone use.
        @Test func theLaunchArgumentIsTheDocumentedOne() {
            #expect(DebugSessionFault.launchArgument == "DEBUG_INVALIDATE_ACCESS_TOKEN")
        }

        @Test func withoutTheArgumentNothingChanges() {
            let live = TestAccessToken.make(expiresIn: 3_600)
            let store = SignOutSessionStorage(accessToken: live)
            // Near misses count as no argument: only the whole word asks for the fault.
            let arguments = [
                "Marauders", "UITEST", "debug_invalidate_access_token", "DEBUG_INVALIDATE_ACCESS_TOKENS",
                "-DEBUG_INVALIDATE_ACCESS_TOKEN",
            ]

            let applied = DebugSessionFault.applyIfRequested(arguments: arguments, tokenStore: store)

            #expect(!applied)
            #expect(store.accessToken == live)
        }

        @Test func withTheArgumentAStoredTokenIsReplacedByAValidFormatToken() throws {
            let live = TestAccessToken.make(expiresIn: 3_600)
            try #require(!APIAccessTokenExpiry.isExpired(live), "the stored token starts out live")
            let store = SignOutSessionStorage(accessToken: live)

            let applied = DebugSessionFault.applyIfRequested(
                arguments: ["Marauders", DebugSessionFault.launchArgument], tokenStore: store)

            let replaced = try #require(store.accessToken)
            #expect(applied)
            #expect(replaced != live)
            #expect(APIAccessTokenFormat.isValid(replaced), "the clients still attach it, so the Worker rejects it")
            #expect(APIAccessTokenExpiry.isExpired(replaced), "it can never pass for a live token")
        }

        @Test func withTheArgumentAndNoTokenNothingIsCreated() {
            let store = SignOutSessionStorage(accessToken: nil)

            let applied = DebugSessionFault.applyIfRequested(
                arguments: [DebugSessionFault.launchArgument], tokenStore: store)

            #expect(!applied)
            #expect(store.accessToken == nil)
        }

        @Test func aTokenThatCannotBeSavedIsNotReportedAsReplaced() {
            let store = UnsavableTokenStore(token: TestAccessToken.make(expiresIn: 3_600))

            let applied = DebugSessionFault.applyIfRequested(
                arguments: [DebugSessionFault.launchArgument], tokenStore: store)

            #expect(!applied)
        }

        @Test func applyingTheFaultIsLoggedWithoutTheStoredToken() async {
            let live = TestAccessToken.make(subject: UUID().uuidString, expiresIn: 3_600)
            let store = SignOutSessionStorage(accessToken: live)

            DebugSessionFault.applyIfRequested(arguments: [DebugSessionFault.launchArgument], tokenStore: store)

            #expect(await logged(.warning, "access token replaced"), "the check on the phone looks for this line")
            let leaked = AppLogStore.shared.entries.contains { $0.message.contains(live) }
            #expect(!leaked, "the stored token never reaches the log")
        }

        /// `AppLog` writes from a task of its own, so an entry shows up a moment after the call that logged it.
        private func logged(_ level: AppLogLevel, _ fragment: String) async -> Bool {
            for _ in 0..<300 {
                let found = AppLogStore.shared.entries.contains {
                    $0.category == "auth" && $0.level == level && $0.message.contains(fragment)
                }
                if found { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }

    /// A Keychain that refuses to write.
    private struct UnsavableTokenStore: APIAccessTokenStore {
        enum Failure: Error { case save }
        let token: String
        func loadAccessToken() -> String? { token }
        func saveAccessToken(_ token: String) throws { throw Failure.save }
        func clearAccessToken() throws {}
    }
#endif
