//
//  SignOutLocationSharingTests.swift
//  MaraudersTests
//

import AuthenticationServices
import CoreLocation
import Foundation
import Testing

@testable import Marauders

// MARK: - the sign out

/// A viewer who signs out must stop showing on their mutual followers' maps. The Worker shows the last location of
/// whoever it says shares, and only a request with the session's token can change that, so `AuthViewModel.signOut()`
/// asks the Worker to switch sharing off before it clears the token, and is never held back by the answer.
@MainActor
struct SignOutLocationSharingTests {
    private static let userID = "001234.abcdef.5678"

    private struct Harness {
        let viewModel: AuthViewModel
        let storage: SignOutSessionStorage
        let repository: SignOutSharingRepository
        let token: String
    }

    /// A signed-in viewer whose sign out asks `repository`, the way the composition root wires it.
    private func makeHarness(sharing: Bool = true, timeout: Duration = .seconds(30)) async -> Harness {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let storage = SignOutSessionStorage(userID: Self.userID, accessToken: token)
        let repository = SignOutSharingRepository(sharing: sharing)
        repository.session = storage
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            authAPI: NoAuthAPI(),
            credentialState: { _ in .authorized }
        )
        viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(repository: repository, timeout: timeout)
        await viewModel.restoreSession()
        return Harness(viewModel: viewModel, storage: storage, repository: repository, token: token)
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

    @Test func signingOutSwitchesSharingOffOnTheWorker() async throws {
        let harness = await makeHarness(sharing: true)
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(harness.repository.calls.map(\.enabled) == [false])
        #expect(!harness.repository.sharing)
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(await logged(.info, "switched off before sign out"))
    }

    /// The Worker only listens to a request that carries the session's token, which the sign out clears.
    @Test func theWorkerIsAskedWhileTheSessionStillHoldsItsToken() async throws {
        let harness = await makeHarness()
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(
            harness.repository.calls == [
                SignOutSharingRepository.Call(enabled: false, accessToken: harness.token, userID: Self.userID)
            ])
    }

    @Test(.timeLimit(.minutes(1)))
    func theViewerStaysSignedInUntilTheWorkerHasAnswered() async throws {
        let gate = SignOutGate()
        let harness = await makeHarness()
        harness.repository.gate = gate

        let signingOut = Task { await harness.viewModel.signOut() }
        await waitUntil { harness.repository.calls.count == 1 }

        #expect(harness.viewModel.isSigningOut)
        #expect(harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == harness.token)

        await gate.open()
        await signingOut.value

        #expect(!harness.viewModel.isSigningOut)
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == nil)
    }

    @Test func aFailedCallDoesNotStopTheSignOutAndIsLogged() async {
        let marker = UUID().uuidString
        let harness = await makeHarness()
        harness.repository.failure = SignOutSharingFailure(marker: marker)

        await harness.viewModel.signOut()

        #expect(harness.repository.calls.count == 1)
        #expect(harness.repository.sharing, "the Worker could not be asked")
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isSigningOut)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(await logged(.warning, marker))
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallThatNeverAnswersDoesNotHoldTheSignOutBack() async {
        let gate = SignOutGate()
        let harness = await makeHarness(timeout: .milliseconds(50))
        harness.repository.gate = gate

        await harness.viewModel.signOut()

        #expect(harness.repository.calls.count == 1)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isSigningOut)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
        #expect(await logged(.warning, "no answer"))
        await gate.open()
    }

    @Test(.timeLimit(.minutes(1)))
    func signingOutTwiceAtOnceAsksTheWorkerOnce() async {
        let gate = SignOutGate()
        let harness = await makeHarness()
        harness.repository.gate = gate

        let first = Task { await harness.viewModel.signOut() }
        await waitUntil { harness.repository.calls.count == 1 }
        // A second tap while the first is under way finds a sign out already running and returns at once.
        await harness.viewModel.signOut()
        #expect(harness.viewModel.isSignedIn, "the first sign out is still waiting")
        await gate.open()
        await first.value

        #expect(harness.repository.calls.count == 1)
        #expect(!harness.viewModel.isSignedIn)
    }

    // MARK: sessions the Worker has already ended

    /// Its token is no use to the Worker any more, so nothing can be asked of it: sharing stays on, as it does when the
    /// app is deleted.
    @Test func aTokenTheWorkerRejectedAsksTheWorkerNothing() async throws {
        let harness = await makeHarness(sharing: true)
        try #require(harness.viewModel.isSignedIn)

        harness.viewModel.handleRejectedAccessToken(harness.token)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.repository.calls.isEmpty)
        #expect(harness.repository.sharing)
    }

    @Test func anExpiredTokenAsksTheWorkerNothing() async {
        let storage = SignOutSessionStorage(userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: -60))
        let repository = SignOutSharingRepository(sharing: true)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            authAPI: NoAuthAPI(),
            credentialState: { _ in .authorized }
        )
        viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(repository: repository)

        await viewModel.restoreSession()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!viewModel.isSignedIn)
        #expect(storage.accessToken == nil)
        #expect(repository.calls.isEmpty)
    }

    @Test func aViewerWhoIsNotSignedInAsksTheWorkerNothing() async {
        let storage = SignOutSessionStorage()
        let repository = SignOutSharingRepository(sharing: true)
        let viewModel = AuthViewModel(sessionStore: storage, tokenStore: storage, authAPI: NoAuthAPI())
        viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(repository: repository)

        await viewModel.signOut()

        #expect(!viewModel.isSignedIn)
        #expect(repository.calls.isEmpty)
    }

    @Test func aSignOutWithNothingWiredStillSignsOut() async throws {
        let harness = await makeHarness()
        harness.viewModel.stopSharingOnSignOut = nil
        try #require(harness.viewModel.isSignedIn)

        await harness.viewModel.signOut()

        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == nil)
        #expect(harness.repository.calls.isEmpty)
    }

    // MARK: the next sign in

    /// What the Settings switch shows comes from the Worker, which now says off: nothing is remembered on the iPhone
    /// that could turn sharing on again, and the viewer chooses once more.
    @Test func afterASignOutTheNextSignInFindsSharingOffAndNothingStartsSendingAgain() async throws {
        let harness = await makeHarness(sharing: true)
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let suiteName = "SignOutLocationSharingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = BackgroundLocationMonitor(
            locationManager: manager,
            report: ReportUserLocationUseCase(repository: RecordingUserLocationRepository()),
            defaults: defaults,
            holdAwake: { _ in {} }
        )
        let friends = FriendLocationsViewModel(
            loadFriends: LoadFriendLocationsUseCase(repository: harness.repository),
            setSharing: SetLocationSharingUseCase(repository: harness.repository),
            backgroundMonitor: monitor
        )
        await friends.refresh()
        try #require(friends.sharing == true)
        try #require(manager.significantChangeStarts == 1)

        await harness.viewModel.signOut()
        // What `ContentView` does when `isSignedIn` turns false.
        friends.reset(signedOut: true)
        try #require(manager.significantChangeStops == 1)

        // The next sign in: the saved choice is not read back, the Worker is asked.
        friends.reset(signedOut: false)
        await friends.refresh()

        #expect(friends.sharing == false)
        #expect(manager.significantChangeStarts == 1, "nothing starts sending again")
        #expect(manager.visitStarts == 1)
        #expect(manager.locationRequestCount == 0)
        #expect(harness.repository.calls.map(\.enabled) == [false], "nothing turned sharing on")
    }

    /// The switch never claims more than the Worker says: when the call could not be made, sharing is still on there.
    @Test func whenTheCallFailedTheNextSignInShowsWhatTheWorkerSays() async {
        let harness = await makeHarness(sharing: true)
        harness.repository.failure = LocationSharingError.serverError(503)
        let friends = FriendLocationsViewModel(
            loadFriends: LoadFriendLocationsUseCase(repository: harness.repository),
            setSharing: SetLocationSharingUseCase(repository: harness.repository)
        )

        await harness.viewModel.signOut()
        friends.reset(signedOut: true)
        friends.reset(signedOut: false)
        await friends.refresh()

        #expect(friends.sharing == true)
    }
}

// MARK: - through the real clients

/// The real clients and the real decorator over a stubbed network, wired the way the composition root wires them.
@Suite(.serialized)
@MainActor
struct SignOutLocationSharingEndToEndTests {
    private static let userID = "001234.abcdef.5678"

    private struct Wiring {
        let viewModel: AuthViewModel
        let storage: SignOutSessionStorage
        let token: String
    }

    private func wire(_ session: URLSession) async -> Wiring {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let storage = SignOutSessionStorage(userID: Self.userID, accessToken: token)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            authAPI: NoAuthAPI(),
            credentialState: { _ in .authorized }
        )
        let base = URLSessionHTTPClient(session: session)
        let transport = RejectedSessionReportingHTTPClient(base: base) { accessToken in
            await viewModel.handleRejectedAccessToken(accessToken)
        }
        let repository = DefaultLocationSharingRepository(
            apiClient: LocationSharingAPIClient(
                client: transport, authorization: SessionAPIAuthorization(tokenStore: storage))
        )
        viewModel.stopSharingOnSignOut = StopLocationSharingOnSignOutUseCase(repository: repository)
        await viewModel.restoreSession()
        return Wiring(viewModel: viewModel, storage: storage, token: token)
    }

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

    @Test func theRequestCarriesTheSessionsTokenAndAsksForSharingOff() async throws {
        var requests: [URLRequest] = []
        let session = StubURLSessionFactory.make { request in
            requests.append(request)
            return (
                StubURLSessionFactory.httpResponse(for: request, statusCode: 200),
                Data(#"{"sharesLocation":false}"#.utf8)
            )
        }
        defer { StubURLSessionFactory.reset(session) }
        let wiring = await wire(session)
        try #require(wiring.viewModel.isSignedIn)

        await wiring.viewModel.signOut()

        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path().hasSuffix("/v1/users/me/location-sharing") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(wiring.token)")
        let sent = try JSONSerialization.jsonObject(with: request.readBody() ?? Data()) as? [String: Bool]
        #expect(sent == ["enabled": false])
        #expect(!wiring.viewModel.isSignedIn)
        #expect(wiring.storage.accessToken == nil)
        #expect(wiring.storage.userID == nil)
    }

    /// A token that went bad since the last request: the Worker answers 401 to the call. That ends the session by
    /// itself, and the sign out the viewer asked for still finishes, once, without asking again.
    @Test func aWorkerThatRejectsTheTokenStillLetsTheSignOutFinish() async throws {
        var requests: [URLRequest] = []
        let session = StubURLSessionFactory.make { request in
            requests.append(request)
            return (
                StubURLSessionFactory.httpResponse(for: request, statusCode: 401),
                Data(#"{"error":"invalid session"}"#.utf8)
            )
        }
        defer { StubURLSessionFactory.reset(session) }
        let wiring = await wire(session)
        try #require(wiring.viewModel.isSignedIn)

        await wiring.viewModel.signOut()

        #expect(requests.count == 1)
        #expect(!wiring.viewModel.isSignedIn)
        #expect(!wiring.viewModel.isSigningOut)
        #expect(wiring.storage.accessToken == nil)
        #expect(wiring.storage.userID == nil)
        #expect(await logged(.warning, "Sign in required"))
    }

    @Test func aWorkerThatIsDownStillLetsTheSignOutFinish() async throws {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 503), Data())
        }
        defer { StubURLSessionFactory.reset(session) }
        let wiring = await wire(session)
        try #require(wiring.viewModel.isSignedIn)

        await wiring.viewModel.signOut()

        #expect(!wiring.viewModel.isSignedIn)
        #expect(wiring.storage.accessToken == nil)
        #expect(await logged(.warning, "Server responded with status 503"))
    }
}

private struct NoAuthAPI: AuthAPIClientProtocol {
    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}
