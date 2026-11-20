//
//  AuthViewModelAccountDeletionTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

/// What the app does to the session once the Worker has deleted the account: what a sign out does, minus everything
/// that asks the Worker, because nothing of the account is left there to switch off or to revoke.
@MainActor
struct AuthViewModelAccountDeletionTests {
    private static let userID = "001234.abcdef.5678"

    private struct Harness {
        let viewModel: AuthViewModel
        let storage: SignOutSessionStorage
        let refreshTokens: MemoryRefreshTokenStore
        let authAPI: CountingAuthAPI
        let uploader: FakeClipUploader
        let sharing: SignOutSharingRepository
    }

    /// A viewer whose session is stored (an access token, a refresh token), wired the way the composition root wires a
    /// sign out: it would switch location sharing off, revoke the refresh token and drop the pending upload.
    private func signedInHarness(hookTimeout: Duration = .seconds(30)) async -> Harness {
        let storage = SignOutSessionStorage(userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: 3_600))
        let refreshTokens = MemoryRefreshTokenStore(
            token: UUID().uuidString.replacingOccurrences(of: "-", with: "") + "-_abcdefghi")
        let authAPI = CountingAuthAPI()
        let uploader = FakeClipUploader()
        let sharing = SignOutSharingRepository(sharing: true)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: refreshTokens,
            authAPI: authAPI,
            credentialState: { _ in .authorized }
        )
        viewModel.discardUploadOnSignOut = ClipUploadUseCases(uploader: uploader).discard
        viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(
            repository: sharing, timeout: .seconds(30))
        viewModel.uploadHookTimeout = hookTimeout
        await viewModel.restoreSession()
        return Harness(
            viewModel: viewModel, storage: storage, refreshTokens: refreshTokens, authAPI: authAPI,
            uploader: uploader, sharing: sharing)
    }

    @Test func finishingADeletionClearsTheSessionAndSignsOut() async throws {
        let harness = await signedInHarness()
        harness.viewModel.errorMessage = "an old message"
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.finishAccountDeletion()

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.viewModel.errorMessage == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.storage.userID == nil)
        #expect(harness.refreshTokens.token == nil, "the refresh token of a deleted account is not kept either")
    }

    /// The Worker is the one that deleted the account. Switching sharing off or revoking a refresh token would be
    /// calls on an account that is gone, and the access token no longer opens anything.
    @Test func itMakesNoCallToTheWorker() async throws {
        // For comparison: a plain sign out of the same kind of session tells the Worker twice.
        let signedOut = await signedInHarness()
        await signedOut.viewModel.signOut()
        try #require(signedOut.sharing.calls.count == 1)
        try #require(signedOut.authAPI.revokes == 1)

        let deleted = await signedInHarness()
        try #require(deleted.viewModel.isSignedIn)
        await deleted.viewModel.finishAccountDeletion()

        #expect(deleted.sharing.calls.isEmpty, "no request to switch sharing off")
        #expect(deleted.authAPI.revokes == 0, "no request to revoke the refresh token")
        #expect(deleted.authAPI.total == 0)
    }

    /// The clip of a deleted account must not stay on the phone, and it is dropped while the session still names the
    /// account, like a sign out does.
    @Test func itDropsThePendingUploadWhileTheSessionIsStillStored() async throws {
        let harness = await signedInHarness()
        let storage = harness.storage
        let token = try #require(storage.accessToken)
        let sighting = DiscardSighting()
        harness.uploader.onDiscard = { sighting.record(storage.accessToken) }

        await harness.viewModel.finishAccountDeletion()

        #expect(harness.uploader.discards == 1)
        #expect(sighting.all == [token], "the token was still stored when the discard arrived")
        #expect(storage.accessToken == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStuckUploadHookNeverHoldsItBack() async {
        let gate = SignOutGate()
        let harness = await signedInHarness(hookTimeout: .milliseconds(50))
        harness.uploader.discardGate = gate

        await harness.viewModel.finishAccountDeletion()

        #expect(harness.uploader.discards == 1)
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        await gate.open()
    }

    #if DEBUG
        /// A test user of the debug sign-in has no Apple ID behind it, so the deletion sheet offers it a plain button.
        private func viewModel(storing userID: String?) -> AuthViewModel {
            let storage = SignOutSessionStorage(
                userID: userID, accessToken: userID == nil ? nil : TestAccessToken.make(expiresIn: 3_600))
            return AuthViewModel(
                sessionStore: storage, tokenStore: storage, refreshTokenStore: MemoryRefreshTokenStore(),
                authAPI: CountingAuthAPI(), credentialState: { _ in .authorized })
        }

        @Test func aStoredDevUserIsATestUser() {
            #expect(viewModel(storing: "dev:ui").isSignedInAsTestUser)
        }

        @Test func anAppleAccountIsNotATestUser() {
            #expect(!viewModel(storing: Self.userID).isSignedInAsTestUser)
        }

        @Test func nobodyStoredIsNotATestUser() {
            #expect(!viewModel(storing: nil).isSignedInAsTestUser)
        }
    #endif
}

/// What the discard of the pending upload saw when it ran. The uploader calls it from its own task and the test reads it
/// afterwards, which the lock makes safe.
private final class DiscardSighting: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String?] = []

    func record(_ value: String?) {
        lock.withLock { seen.append(value) }
    }

    var all: [String?] { lock.withLock { seen } }
}

/// The Worker's auth routes as a sign out meets them: it counts every call, and answers a revoke.
private final class CountingAuthAPI: AuthAPIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges = 0
    private var refreshes = 0
    private var revoked = 0

    var revokes: Int { lock.withLock { revoked } }
    var total: Int { lock.withLock { exchanges + refreshes + revoked } }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        lock.withLock { exchanges += 1 }
        throw AuthAPIError.invalidResponse
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        lock.withLock { refreshes += 1 }
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        lock.withLock { revoked += 1 }
    }
}
