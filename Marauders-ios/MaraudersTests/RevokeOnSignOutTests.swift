//
//  RevokeOnSignOutTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

/// Signing out ends the session on the Worker too: the refresh token is revoked, inside the same window as the location
/// sharing call and without ever holding the sign out back. A session that ended without the viewer asking has no
/// working token to revoke with, so it asks the Worker nothing.
@MainActor
struct RevokeOnSignOutTests {
    private static let userID = "001234.abcdef.5678"

    /// A refresh token of the real shape (43 base64url characters) that no other test uses.
    private static func newRefreshToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + "-_abcdefghi"
    }

    private struct Harness {
        let viewModel: AuthViewModel
        let storage: SignOutSessionStorage
        let refresh: MemoryRefreshTokenStore
        let authAPI: RevokingAuthAPI
        let repository: SignOutSharingRepository
        let accessToken: String
    }

    /// A viewer with a saved session whose sign out asks `repository` first and the Worker's `authAPI` second, both
    /// inside `window`, the way the composition root wires it. The session is not restored yet.
    ///
    /// `switchesSharingOff: false` leaves the sharing call out. A test of the revoke alone in a window of a few hundred
    /// milliseconds needs it: a sharing call that a busy machine slowed down would use the window up, and the revoke
    /// would never be made.
    private func makeHarness(
        accessToken: String = TestAccessToken.make(expiresIn: 3_600),
        refreshToken: String? = RevokeOnSignOutTests.newRefreshToken(),
        window: Duration = .seconds(30),
        behavior: RevokingAuthAPI.Behavior = .answers,
        switchesSharingOff: Bool = true,
        apple: ASAuthorizationAppleIDProvider.CredentialState = .authorized
    ) -> Harness {
        let storage = SignOutSessionStorage(userID: Self.userID, accessToken: accessToken)
        let refresh = MemoryRefreshTokenStore(token: refreshToken)
        let authAPI = RevokingAuthAPI(behavior: behavior)
        authAPI.refreshStore = refresh
        authAPI.accessStore = storage
        let repository = SignOutSharingRepository(sharing: true)
        repository.session = storage
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: refresh,
            authAPI: authAPI,
            credentialState: { _ in apple },
            signOutWindow: window
        )
        if switchesSharingOff {
            viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(
                repository: repository, timeout: window)
        }
        return Harness(
            viewModel: viewModel, storage: storage, refresh: refresh, authAPI: authAPI, repository: repository,
            accessToken: accessToken)
    }

    private func signedIn(
        refreshToken: String? = RevokeOnSignOutTests.newRefreshToken(),
        window: Duration = .seconds(30),
        behavior: RevokingAuthAPI.Behavior = .answers,
        switchesSharingOff: Bool = true
    ) async -> Harness {
        let harness = makeHarness(
            refreshToken: refreshToken, window: window, behavior: behavior, switchesSharingOff: switchesSharingOff)
        await harness.viewModel.restoreSession()
        return harness
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

    @Test func signingOutRevokesTheStoredRefreshTokenBeforeClearing() async throws {
        let token = Self.newRefreshToken()
        let harness = await signedIn(refreshToken: token)
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(
            harness.authAPI.calls == [
                RevokingAuthAPI.Call(token: token, storedRefreshToken: token, storedAccessToken: harness.accessToken)
            ], "the Worker is asked while the session still holds both tokens")
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.refresh.token == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func signingOutIsNotHeldBackByARevokeThatNeverAnswers() async throws {
        let gate = SignOutGate()
        let harness = await signedIn(window: .milliseconds(300), behavior: .stuck(gate), switchesSharingOff: false)
        try #require(harness.viewModel.isSignedIn)

        let clock = ContinuousClock()
        let started = clock.now
        await harness.viewModel.signOut()
        let elapsed = started.duration(to: clock.now)

        // Far under the time limit: a revoke that held the sign out back would never end, since the gate stays shut.
        #expect(elapsed < .seconds(10))
        #expect(harness.authAPI.calls.count == 1)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isSigningOut)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.refresh.token == nil)
        await gate.open()
    }

    @Test func aFailedRevokeStillSignsOut() async throws {
        let harness = await signedIn(behavior: .fails(SignOutSharingFailure(marker: UUID().uuidString)))
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(harness.authAPI.calls.count == 1)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isSigningOut)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.refresh.token == nil)
    }

    @Test func signingOutWithoutARefreshTokenCallsNothing() async throws {
        let harness = await signedIn(refreshToken: nil)
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(harness.authAPI.calls.isEmpty)
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == nil)
    }

    /// Sharing is switched off with the access token, and that call can meet a 401 and trigger a refresh, which swaps
    /// the stored refresh token. The revoke must name the token that is stored by the time it is made.
    @Test func theRevokeUsesTheTokenStoredAfterSharingWasSwitchedOff() async throws {
        let rewritten = Self.newRefreshToken()
        let harness = await signedIn()
        try #require(harness.viewModel.isSignedIn)
        harness.repository.whileAsked = { [refresh = harness.refresh] in refresh.token = rewritten }

        await harness.viewModel.signOut()

        #expect(harness.repository.calls.count == 1)
        #expect(harness.authAPI.calls.map(\.token) == [rewritten])
    }

    @Test(.timeLimit(.minutes(1)))
    func aRevokeIsSkippedWhenSharingUsedTheWholeWindow() async throws {
        let gate = SignOutGate()
        let harness = await signedIn(window: .milliseconds(200))
        try #require(harness.viewModel.isSignedIn)
        // Sharing never answers, so it is given up when the window ends and nothing is left for the revoke.
        harness.repository.gate = gate

        await harness.viewModel.signOut()

        #expect(harness.repository.calls.count == 1)
        #expect(harness.authAPI.calls.isEmpty)
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.refresh.token == nil)
        #expect(await logged(.warning, "no time left"))
        await gate.open()
    }

    @Test func endedSessionsRevokeNothing() async throws {
        // The Worker rejected the access token.
        let rejected = await signedIn()
        try #require(rejected.viewModel.isSignedIn)
        rejected.viewModel.handleRejectedAccessToken(rejected.accessToken)

        // Apple says the account behind the session was revoked.
        let revoked = makeHarness(apple: .revoked)
        await revoked.viewModel.restoreSession()

        // The access token ran out and there is no refresh token to renew it with.
        let expired = makeHarness(accessToken: TestAccessToken.make(expiresIn: -60), refreshToken: nil)
        await expired.viewModel.restoreSession()

        try? await Task.sleep(for: .milliseconds(50))
        for (reason, harness) in [("rejected", rejected), ("revoked", revoked), ("expired", expired)] {
            #expect(!harness.viewModel.isSignedIn, "\(reason): the session is over")
            #expect(harness.authAPI.calls.isEmpty, "\(reason): nothing to revoke with")
        }
    }

    @Test func aFailedOrTimedOutRevokeIsLoggedWithoutTheToken() async throws {
        let marker = UUID().uuidString
        let failingToken = Self.newRefreshToken()
        let failing = await signedIn(
            refreshToken: failingToken, behavior: .fails(SignOutSharingFailure(marker: marker)))
        await failing.viewModel.signOut()
        #expect(await logged(.warning, "refresh token not revoked before sign out: the Worker said \(marker)"))

        let gate = SignOutGate()
        let stuckToken = Self.newRefreshToken()
        let stuck = await signedIn(
            refreshToken: stuckToken, window: .milliseconds(200), behavior: .stuck(gate), switchesSharingOff: false)
        await stuck.viewModel.signOut()
        #expect(await logged(.warning, "refresh token not revoked before sign out: no answer in time"))
        await gate.open()

        for token in [failingToken, stuckToken] {
            let leaked = AppLogStore.shared.entries.contains { $0.message.contains(token) }
            #expect(!leaked, "the token never reaches the log")
        }
    }
}

/// The Worker's sign-out route as a sign out meets it: it remembers every refresh token it was asked to revoke together
/// with what the stores held at that moment, and can fail or never answer.
private final class RevokingAuthAPI: AuthAPIClientProtocol, @unchecked Sendable {
    enum Behavior {
        case answers
        case fails(any Error)
        /// Waits at the gate and ignores cancellation, like a transport that is stuck.
        case stuck(SignOutGate)
    }

    struct Call: Equatable {
        let token: String
        /// What the stores held when the call arrived.
        let storedRefreshToken: String?
        let storedAccessToken: String?
    }

    private let behavior: Behavior
    var refreshStore: MemoryRefreshTokenStore?
    var accessStore: SignOutSessionStorage?
    private(set) var calls: [Call] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        calls.append(
            Call(
                token: refreshToken,
                storedRefreshToken: refreshStore?.token,
                storedAccessToken: accessStore?.accessToken
            ))
        switch behavior {
        case .answers:
            return
        case .fails(let error):
            throw error
        case .stuck(let gate):
            await gate.wait()
        }
    }
}
