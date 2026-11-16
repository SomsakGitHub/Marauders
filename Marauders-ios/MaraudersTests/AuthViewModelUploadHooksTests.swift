//
//  AuthViewModelUploadHooksTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders

/// What a sign out and a sign in do about the viewer's pending upload. A sign out drops it while the session still
/// holds its token, so nothing of the account stays on the phone. A sign in lets the uploader check it against the
/// account that signed in before the viewer is signed in, so a clip of another account is never sent under the new
/// one. A session that the Worker ended, or that ran out, keeps the upload: the same account can sign in and try again.
@MainActor
struct AuthViewModelUploadHooksTests {
    private static let userID = "001234.abcdef.5678"
    private static let identityToken = String(repeating: "i", count: 32)

    private struct Harness {
        let viewModel: AuthViewModel
        let storage: SignOutSessionStorage
        let uploader: FakeClipUploader
    }

    /// What the check of a sign in found when it ran.
    private struct CheckSighting: Equatable {
        let isSignedIn: Bool
        let storedToken: String?
    }

    /// A view model wired to a `FakeClipUploader` the way the composition root wires it, over `storage`.
    private func makeHarness(
        storage: SignOutSessionStorage,
        authAPI: any AuthAPIClientProtocol = SignInAPI(result: .failure(AuthAPIError.invalidResponse)),
        hookTimeout: Duration = .seconds(30)
    ) async -> Harness {
        let uploader = FakeClipUploader()
        let uploads = ClipUploadUseCases(uploader: uploader)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: MemoryRefreshTokenStore(),
            authAPI: authAPI,
            credentialState: { _ in .authorized }
        )
        viewModel.discardUploadOnSignOut = uploads.discard
        viewModel.checkUploadOnSignIn = uploads.reconcile
        viewModel.uploadHookTimeout = hookTimeout
        await viewModel.restoreSession()
        return Harness(viewModel: viewModel, storage: storage, uploader: uploader)
    }

    /// A viewer whose session is stored, signed in once the session is restored.
    private func signedInHarness(
        token: String = TestAccessToken.make(expiresIn: 3_600), hookTimeout: Duration = .seconds(30)
    ) async -> Harness {
        await makeHarness(
            storage: SignOutSessionStorage(userID: Self.userID, accessToken: token), hookTimeout: hookTimeout)
    }

    /// A viewer with no session, whose sign in the Worker answers with `result`.
    private func signedOutHarness(
        signInResult: Result<AuthTokens, any Error>, hookTimeout: Duration = .seconds(30)
    ) async -> Harness {
        await makeHarness(
            storage: SignOutSessionStorage(), authAPI: SignInAPI(result: signInResult), hookTimeout: hookTimeout)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

    // MARK: - the sign out

    /// The viewer asked to sign out, so their clip goes too. It is dropped while the session is still stored: were the
    /// session cleared first, a sign out that is cut short would leave a clip that no session owns.
    @Test func signingOutDiscardsTheUploadBeforeTheSessionIsCleared() async throws {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let harness = await signedInHarness(token: token)
        let storage = harness.storage
        let sighting = Sighting<String?>()
        harness.uploader.onDiscard = { sighting.record(storage.accessToken) }
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(harness.uploader.discards == 1)
        #expect(sighting.all == [token], "the token was still stored when the discard arrived")
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.storage.userID == nil)
    }

    /// A viewer whose session already ended can still tap Sign Out: whatever upload the phone holds goes too.
    @Test func signingOutDiscardsTheUploadEvenWhenNotSignedIn() async throws {
        let harness = await signedOutHarness(signInResult: .failure(AuthAPIError.invalidResponse))
        try #require(!harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(harness.uploader.discards == 1)
        #expect(!harness.viewModel.isSignedIn)
    }

    /// The Worker is asked first, with the session whole, and the upload is dropped once it has answered.
    @Test(.timeLimit(.minutes(1)))
    func signingOutAsksTheWorkerBeforeItDiscardsTheUpload() async throws {
        let harness = await signedInHarness()
        let repository = SignOutSharingRepository(sharing: true)
        let gate = SignOutGate()
        repository.gate = gate
        harness.viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(
            repository: repository, timeout: .seconds(30))
        try #require(harness.viewModel.isSignedIn)

        let signingOut = Task { await harness.viewModel.signOut() }
        await waitUntil { repository.calls.count == 1 }
        #expect(harness.uploader.discards == 0, "the Worker has not answered yet")

        await gate.open()
        await signingOut.value

        #expect(harness.uploader.discards == 1)
        #expect(!harness.viewModel.isSignedIn)
    }

    /// The Worker ended this session, not the viewer: the same account can sign in again and try the upload again.
    @Test func aSessionEndedByRejectionKeepsTheUpload() async throws {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let harness = await signedInHarness(token: token)
        try #require(harness.viewModel.isSignedIn)

        harness.viewModel.handleRejectedAccessToken(token)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.uploader.discards == 0)
    }

    /// A token that ran out ends the session at launch, the same way: nothing is dropped.
    @Test func aSessionClearedWhileRestoringKeepsTheUpload() async {
        let harness = await signedInHarness(token: TestAccessToken.make(expiresIn: -60))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == nil, "the expired session was cleared")
        #expect(harness.uploader.discards == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDiscardThatNeverReturnsDoesNotHoldTheSignOutBack() async {
        let gate = SignOutGate()
        let harness = await signedInHarness(hookTimeout: .milliseconds(50))
        harness.uploader.discardGate = gate

        await harness.viewModel.signOut()

        #expect(harness.uploader.discards == 1)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isSigningOut)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(await logged(.warning, "upload not discarded before sign out: no answer"))
        await gate.open()
    }

    // MARK: - the sign in

    /// The check reads the account of the token that was just stored, so another account's clip is dropped before the
    /// new viewer can see it or try it again.
    @Test func signingInChecksTheStoredUploadBeforeTheViewerIsSignedIn() async throws {
        let token = TestAccessToken.make(subject: "new-user", expiresIn: 3_600)
        let harness = await signedOutHarness(
            signInResult: .success(AuthTokens(accessToken: token, refreshToken: nil)))
        let viewModel = harness.viewModel
        let storage = harness.storage
        let sighting = Sighting<CheckSighting>()
        harness.uploader.onReconcile = {
            let isSignedIn = await MainActor.run { viewModel.isSignedIn }
            sighting.record(CheckSighting(isSignedIn: isSignedIn, storedToken: storage.accessToken))
        }
        try #require(!viewModel.isSignedIn)

        await viewModel.completeSignIn(userID: Self.userID, identityToken: Self.identityToken)

        #expect(harness.uploader.reconciles == 1)
        #expect(sighting.all == [CheckSighting(isSignedIn: false, storedToken: token)])
        #expect(viewModel.isSignedIn)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func aFailedSignInChecksNothing() async {
        let harness = await signedOutHarness(signInResult: .failure(AuthAPIError.serverError(503)))

        await harness.viewModel.completeSignIn(userID: Self.userID, identityToken: Self.identityToken)

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.uploader.reconciles == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCheckThatNeverReturnsDoesNotHoldTheSignInBack() async {
        let token = TestAccessToken.make(subject: "new-user", expiresIn: 3_600)
        let gate = SignOutGate()
        let harness = await signedOutHarness(
            signInResult: .success(AuthTokens(accessToken: token, refreshToken: nil)),
            hookTimeout: .milliseconds(50))
        harness.uploader.onReconcile = { await gate.wait() }

        await harness.viewModel.completeSignIn(userID: Self.userID, identityToken: Self.identityToken)

        #expect(harness.uploader.reconciles == 1)
        #expect(harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == token)
        #expect(await logged(.warning, "upload not checked before sign in: no answer"))
        await gate.open()
    }

    /// Opening the app with a saved session asks the uploader nothing here: `launch()` is the one check of a launch.
    @Test func restoringASavedSessionChecksNothing() async {
        let harness = await signedInHarness()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.viewModel.isSignedIn)
        #expect(harness.uploader.reconciles == 0)
    }
}

// MARK: - doubles

/// What a hook saw when it ran. A hook runs on the uploader's task and the test reads what it saw afterwards, which the
/// lock makes safe.
private final class Sighting<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Value] = []

    func record(_ value: Value) {
        lock.withLock { seen.append(value) }
    }

    var all: [Value] { lock.withLock { seen } }
}

/// The Worker's sign in route: every exchange gets `result`. The two other routes are not used here.
private struct SignInAPI: AuthAPIClientProtocol {
    let result: Result<AuthTokens, any Error>

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        try result.get()
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}
