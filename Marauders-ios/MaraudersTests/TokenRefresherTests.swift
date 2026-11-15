//
//  TokenRefresherTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What a request that met a 401 gets from the refresher: one call to the Worker however many requests met it, the
/// session's own tokens and nobody else's, and nothing written once the session it was made for is gone.
@MainActor
struct TokenRefresherTests {
    /// A viewer with a saved session whose access token the Worker just rejected. The Worker will hand out `a2` and `r2`
    /// in exchange for `r1`. `a1` and `a2` differ in `exp` because a test token is built from whole seconds: the same
    /// claims in the same second make the same token.
    private struct Harness {
        let stores: RecordingTokenStores
        let api: ScriptedAuthAPI
        let refresher: TokenRefresher
        let a1 = TestAccessToken.make(subject: "user-1", expiresIn: 60)
        let a2 = TestAccessToken.make(subject: "user-1", expiresIn: 86_400)
        let r1 = newRefreshToken()
        let r2 = newRefreshToken()

        var pair: AuthTokens { AuthTokens(accessToken: a2, refreshToken: r2) }

        /// Everything in this harness that must never reach a log.
        var secrets: [String] { [a1, a2, r1, r2] }

        init(gate: SignOutGate? = nil) {
            api = ScriptedAuthAPI(gate: gate)
            stores = RecordingTokenStores()
            refresher = TokenRefresher(
                accessTokenStore: stores, refreshTokenStore: stores, authAPI: api, retryDelay: .zero)
            stores.accessToken = a1
            stores.refreshToken = r1
        }
    }

    // MARK: - one call for everyone who met the rejection

    @Test(.timeLimit(.minutes(1)))
    func manyCallersThatMeetTheSameRejectionMakeOneCall() async throws {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.success(h.pair))

        let callers = (0..<8).map { _ in Task { await h.refresher.refreshedAccessToken(replacing: h.a1) } }
        await h.api.waitForCalls(1)
        // Time for the other seven to reach the refresher and wait for the call that is in flight.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()

        for caller in callers {
            #expect(await caller.value.refreshedToken == h.a2)
        }
        #expect(h.api.refreshCalls == 1)
        #expect(h.stores.accessToken == h.a2)
        #expect(h.stores.refreshToken == h.r2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerWithAnOlderTokenOfTheSameAccountSharesTheCallThatIsInFlight() async throws {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.failure(AuthAPIError.serverError(500)))
        let older = TestAccessToken.make(subject: "user-1", expiresIn: 30)

        let starter = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        let joiner = Task { await h.refresher.refreshedAccessToken(replacing: older) }
        // Time for the joiner to reach the refresher and wait for the call that is in flight.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()

        // The same account, so the same answer. Looking at the store instead would hand it the token just rejected.
        #expect(await starter.value.unavailableError as? AuthAPIError == .serverError(500))
        #expect(await joiner.value.unavailableError as? AuthAPIError == .serverError(500))
        #expect(h.api.refreshCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerOfAnotherAccountIsNotHandedTheTokenOfARefreshThatIsInFlight() async throws {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.success(h.pair))
        let anotherAccount = TestAccessToken.make(subject: "user-2", expiresIn: 60)

        let starter = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        let joiner = Task { await h.refresher.refreshedAccessToken(replacing: anotherAccount) }
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()

        #expect(await starter.value.refreshedToken == h.a2)
        // A request of the second account is never replayed with the first account's token.
        #expect(await joiner.value.isRejected)
        #expect(h.api.refreshCalls == 1)
        #expect(h.stores.accessToken == h.a2)
        #expect(h.stores.refreshToken == h.r2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerWhoseSessionIsTheStoredOneIsNotGivenTheVerdictOnSomeoneElsesRefresh() async throws {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        let otherAccessToken = TestAccessToken.make(subject: "user-2", expiresIn: 60)
        let otherRefreshToken = newRefreshToken()
        let otherNewAccessToken = TestAccessToken.make(subject: "user-2", expiresIn: 86_400)
        let otherNewRefreshToken = newRefreshToken()
        h.api.enqueue(.success(h.pair))
        h.api.enqueue(.success(AuthTokens(accessToken: otherNewAccessToken, refreshToken: otherNewRefreshToken)))

        let starter = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        // The viewer signs out and someone else signs in while the Worker is still answering; their token is rejected.
        h.stores.accessToken = otherAccessToken
        h.stores.refreshToken = otherRefreshToken
        let joiner = Task { await h.refresher.refreshedAccessToken(replacing: otherAccessToken) }
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()

        // The call in the air was for the first viewer and writes nothing now. The second viewer's own refresh follows.
        #expect(await starter.value.isRejected)
        #expect(await joiner.value.refreshedToken == otherNewAccessToken)
        #expect(h.api.refreshTokensGiven == [h.r1, otherRefreshToken])
        #expect(h.stores.accessToken == otherNewAccessToken)
        #expect(h.stores.refreshToken == otherNewRefreshToken)
    }

    @Test func aCallerWhoseTokenWasAlreadyReplacedGetsTheStoredOneWithoutACall() async {
        let h = Harness()
        // An earlier refresh already stored the new pair; this caller met the rejection with the old token.
        h.stores.accessToken = h.a2
        h.stores.refreshToken = h.r2

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.refreshedToken == h.a2)
        #expect(h.api.refreshCalls == 0)
        #expect(h.stores.events.isEmpty)
    }

    @Test(arguments: SubjectMismatch.allCases)
    func aStoredTokenOfAnotherAccountIsNeverHandedOut(mismatch: SubjectMismatch) async {
        let h = Harness()
        let anotherAccount = TestAccessToken.make(subject: "user-2", expiresIn: 86_400)
        let withoutSubject = TestAccessToken.make(claims: ["exp": Int(Date().timeIntervalSince1970) + 86_400])
        let alsoWithoutSubject = TestAccessToken.make(claims: ["exp": Int(Date().timeIntervalSince1970) + 7_200])
        var rejected = h.a1
        switch mismatch {
        case .anotherAccount:
            h.stores.accessToken = anotherAccount
        case .storedTokenHasNoSubject:
            h.stores.accessToken = withoutSubject
        case .rejectedTokenHasNoSubject:
            h.stores.accessToken = h.a2
            rejected = withoutSubject
        case .neitherHasASubject:
            h.stores.accessToken = withoutSubject
            rejected = alsoWithoutSubject
        }

        let outcome = await h.refresher.refreshedAccessToken(replacing: rejected)

        #expect(outcome.isRejected)
        #expect(h.api.refreshCalls == 0)
        #expect(h.stores.events.isEmpty)
    }

    // MARK: - nothing to refresh with

    @Test func noStoredSessionIsRejected() async {
        let refreshTokens: [String?] = [nil, newRefreshToken()]
        for refreshToken in refreshTokens {
            let h = Harness()
            h.stores.accessToken = nil
            h.stores.refreshToken = refreshToken

            let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

            #expect(outcome.isRejected)
            #expect(h.api.refreshCalls == 0)
            #expect(h.stores.events.isEmpty)
        }
    }

    @Test func noRefreshTokenIsRejected() async {
        let h = Harness()
        h.stores.refreshToken = nil

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.isRejected)
        #expect(h.api.refreshCalls == 0)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
    }

    @Test(arguments: [
        "",
        "too-short",
        String(repeating: "a", count: 300),
        "this one is long enough but has spaces and + and / in it",
        "padded-base64url-is-not-what-the-worker-issues=",
    ])
    func aMalformedRefreshTokenIsRejected(stored: String) async {
        let h = Harness()
        h.stores.refreshToken = stored

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.isRejected)
        #expect(h.api.refreshCalls == 0)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.refreshToken == stored)
    }

    // MARK: - what the Worker answers

    @Test func aNewPairReplacesBothStoredTokens() async {
        let h = Harness()
        h.api.enqueue(.success(h.pair))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.refreshedToken == h.a2)
        #expect(h.api.refreshTokensGiven == [h.r1])
        #expect(h.stores.accessToken == h.a2)
        #expect(h.stores.refreshToken == h.r2)
    }

    @Test func aRefusedRefreshTokenIsRejectedAndTheStoresAreLeftToTheCaller() async {
        let h = Harness()
        h.api.enqueue(.failure(AuthAPIError.refreshRejected))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.isRejected)
        #expect(h.api.refreshCalls == 1)
        // Ending the session is the caller's decision: the refresher never clears anything.
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.refreshToken == h.r1)
    }

    @Test(arguments: [
        AuthAPIError.serverError(429),
        AuthAPIError.serverError(500),
        AuthAPIError.serverError(404),
        AuthAPIError.serverError(405),
        AuthAPIError.invalidResponse,
    ])
    func anAnswerThatIsNotAVerdictKeepsTheSessionAndIsNotRepeated(answer: AuthAPIError) async {
        let h = Harness()
        h.api.enqueue(.failure(answer))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.unavailableError as? AuthAPIError == answer)
        #expect(h.api.refreshCalls == 1)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.refreshToken == h.r1)
    }

    @Test(arguments: [nil, "short", "has spaces and is not what the worker issues, even at this length"])
    func aPairWithoutAUsableRefreshTokenIsABrokenAnswer(refreshToken: String?) async {
        let h = Harness()
        h.api.enqueue(.success(AuthTokens(accessToken: h.a2, refreshToken: refreshToken)))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.unavailableError as? AuthAPIError == .invalidResponse)
        #expect(h.api.refreshCalls == 1)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.refreshToken == h.r1)
    }

    // MARK: - a transport failure is repeated once

    @Test(arguments: [
        URLError(.timedOut) as any Error,
        URLError(.networkConnectionLost),
        AuthAPIError.serverError(502),
        AuthAPIError.serverError(503),
        AuthAPIError.serverError(504),
        HTTPClientError.transport("offline"),
        HTTPClientError.invalidResponse,
    ])
    func aTransportFailureIsRepeatedOnce(failure: any Error) async {
        let h = Harness()
        h.api.enqueue(.failure(failure))
        h.api.enqueue(.success(h.pair))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.refreshedToken == h.a2)
        #expect(h.api.refreshTokensGiven == [h.r1, h.r1], "the repeat carries the same token: the Worker takes it twice")
        #expect(h.stores.accessToken == h.a2)
        #expect(h.stores.refreshToken == h.r2)
    }

    @Test(arguments: [
        URLError(.timedOut) as any Error,
        AuthAPIError.serverError(502),
        AuthAPIError.serverError(503),
        AuthAPIError.serverError(504),
        HTTPClientError.transport("offline"),
    ])
    func aTransportFailureThatRepeatsIsGivenUpOn(failure: any Error) async {
        let h = Harness()
        h.api.enqueue(.failure(failure))
        h.api.enqueue(.failure(failure))
        h.api.enqueue(.success(h.pair))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.unavailableError.map { String(reflecting: $0) } == String(reflecting: failure))
        #expect(h.api.refreshCalls == 2, "once more, not until it works")
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.refreshToken == h.r1)
    }

    @Test func aRepeatThatIsRefusedEndsTheSession() async {
        let h = Harness()
        h.api.enqueue(.failure(URLError(.timedOut)))
        h.api.enqueue(.failure(AuthAPIError.refreshRejected))

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.isRejected)
        #expect(h.api.refreshCalls == 2)
        #expect(h.stores.events.isEmpty)
    }

    // MARK: - saving the new pair

    @Test func theNewRefreshTokenIsSavedBeforeTheAccessToken() async {
        let h = Harness()
        h.api.enqueue(.success(h.pair))

        _ = await h.refresher.refreshedAccessToken(replacing: h.a1)

        // The old refresh token is spent the moment the Worker answers, so the new one is the first thing to keep.
        #expect(h.stores.events == ["refresh", "access"])
    }

    @Test func anAccessTokenThatCannotBeSavedLeavesTheNewRefreshTokenStored() async {
        let h = Harness()
        h.api.enqueue(.success(h.pair))
        h.stores.accessSaveError = KeychainFailure()

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.unavailableError is KeychainFailure)
        #expect(h.stores.refreshToken == h.r2)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.events == ["refresh"])
    }

    @Test func aRefreshTokenThatCannotBeSavedWritesNothingElse() async {
        let h = Harness()
        h.api.enqueue(.success(h.pair))
        h.stores.refreshSaveError = KeychainFailure()

        let outcome = await h.refresher.refreshedAccessToken(replacing: h.a1)

        #expect(outcome.unavailableError is KeychainFailure)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == h.a1)
        #expect(h.stores.refreshToken == h.r1)
    }

    // MARK: - the session changes while the Worker is answering

    @Test(.timeLimit(.minutes(1)))
    func aRefreshThatFinishesAfterSignOutWritesNothing() async {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.success(h.pair))

        let caller = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        // The viewer signs out while the Worker is still answering.
        h.stores.accessToken = nil
        h.stores.refreshToken = nil
        await gate.open()

        #expect(await caller.value.isRejected)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == nil)
        #expect(h.stores.refreshToken == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshThatFinishesAfterANewSignInWritesNothing() async {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.success(h.pair))
        let otherAccessToken = TestAccessToken.make(subject: "user-2", expiresIn: 86_400)
        let otherRefreshToken = newRefreshToken()

        let caller = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        // Someone else signs in on this device while the Worker is still answering.
        h.stores.accessToken = otherAccessToken
        h.stores.refreshToken = otherRefreshToken
        await gate.open()

        #expect(await caller.value.isRejected)
        #expect(h.stores.events.isEmpty)
        #expect(h.stores.accessToken == otherAccessToken)
        #expect(h.stores.refreshToken == otherRefreshToken)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledCallerDoesNotCancelTheRefresh() async {
        let gate = SignOutGate()
        let h = Harness(gate: gate)
        h.api.enqueue(.success(h.pair))

        let caller = Task { await h.refresher.refreshedAccessToken(replacing: h.a1) }
        await h.api.waitForCalls(1)
        caller.cancel()
        await gate.open()

        // The caller only stops being a reason to wait: the refresh finishes for everyone else and for the caller too.
        #expect(await caller.value.refreshedToken == h.a2)
        #expect(h.stores.accessToken == h.a2)
        #expect(h.stores.refreshToken == h.r2)
        #expect(await h.refresher.refreshedAccessToken(replacing: h.a1).refreshedToken == h.a2)
        #expect(h.api.refreshCalls == 1)
    }

    // MARK: - the log

    @Test(.timeLimit(.minutes(1)))
    func noTokenReachesTheAppLog() async {
        // A refresh that works, one the Worker refuses and one it cannot answer: the three lines the refresher logs.
        let works = Harness()
        works.api.enqueue(.success(works.pair))
        let refused = Harness()
        refused.api.enqueue(.failure(AuthAPIError.refreshRejected))
        let unanswered = Harness()
        unanswered.api.enqueue(.failure(AuthAPIError.serverError(500)))
        let harnesses = [works, refused, unanswered]

        for h in harnesses {
            _ = await h.refresher.refreshedAccessToken(replacing: h.a1)
        }

        for line in ["refreshed", "rejected", "unavailable (AuthAPIError)"] {
            #expect(await logged(line), "\(line) is in the log")
        }
        for secret in harnesses.flatMap(\.secrets) {
            #expect(!AppLogStore.shared.entries.contains { $0.message.contains(secret) }, "no token reaches the log")
        }
    }

    /// `AppLog` writes from a task of its own, so an entry shows up a moment after the call that logged it.
    private func logged(_ message: String) async -> Bool {
        for _ in 0..<300 {
            if AppLogStore.shared.entries.contains(where: { $0.category == "api.refresh" && $0.message == message }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

// MARK: - the subject of an access token

struct APIAccessTokenSubjectTests {
    @Test func readsTheSubjectOfAWorkerShapedToken() {
        let token = TestAccessToken.make(subject: "3f2a9c1e-user", expiresIn: 3_600)

        #expect(APIAccessTokenSubject.subject(of: token) == "3f2a9c1e-user")
    }

    @Test func readsTheSubjectWhateverElseTheTokenCarries() {
        #expect(APIAccessTokenSubject.subject(of: TestAccessToken.make(claims: ["sub": "user-1"])) == "user-1")
    }

    @Test func surroundingWhitespaceDoesNotHideTheSubject() {
        let token = TestAccessToken.make(subject: "user-1", expiresIn: 3_600)

        #expect(APIAccessTokenSubject.subject(of: "  \(token)\n") == "user-1")
    }

    /// A payload whose standard base64 would hold `+` and `/` is sent with `-` and `_`, and without padding.
    @Test func readsTheBase64URLAlphabetWithoutPadding() throws {
        let subject = String(repeating: "???>>>", count: 6)
        let token = TestAccessToken.make(claims: ["sub": subject, "exp": 1_800_000_000])
        let payload = try #require(token.split(separator: ".").dropFirst().first)
        try #require(payload.contains("-") || payload.contains("_"), "the fixture must use the URL alphabet")
        try #require(!payload.contains("="))

        #expect(APIAccessTokenSubject.subject(of: token) == subject)
    }

    @Test(arguments: [
        "",
        "   ",
        "x",
        "only.two",
        "one.two.three.four",
        "aaa..ccc",
        "header.!!!.signature",
        "header.a.signature",
        "header.bm90LWpzb24.signature",
    ])
    func aStringThatIsNotAJWTHasNoSubject(token: String) {
        #expect(APIAccessTokenSubject.subject(of: token) == nil)
    }

    @Test(arguments: [
        #"{"exp":1900000000}"#,
        #"{"sub":42}"#,
        #"{"sub":true}"#,
        #"{"sub":null}"#,
        #"{"sub":["user-1"]}"#,
        #"{"sub":{"id":"user-1"}}"#,
        #"{"sub":""}"#,
        #"["sub","user-1"]"#,
        #""user-1""#,
        #"{}"#,
        "",
    ])
    func aSubjectThatIsNotAStringCannotBeRead(payload: String) {
        let token = TestAccessToken.make(payload: Data(payload.utf8))

        #expect(APIAccessTokenSubject.subject(of: token) == nil)
    }
}

// MARK: - doubles

/// How the token the Worker rejected and the token that is stored can fail to be the same account's.
nonisolated enum SubjectMismatch: CaseIterable, Sendable {
    case anotherAccount
    case storedTokenHasNoSubject
    case rejectedTokenHasNoSubject
    case neitherHasASubject
}

private struct KeychainFailure: Error {}

private func newRefreshToken() -> String {
    // 32 hex characters and 11 more make 43 base64url characters, the shape the Worker issues.
    UUID().uuidString.replacingOccurrences(of: "-", with: "") + "-_abcdefghi"
}

private extension TokenRefreshOutcome {
    var refreshedToken: String? {
        if case .refreshed(let token) = self { return token }
        return nil
    }

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    var unavailableError: (any Error)? {
        if case .unavailable(let error) = self { return error }
        return nil
    }
}

/// Both token stores of one session in one object, so the order of the refresher's writes across the two can be read
/// from `events`. A test sets `accessToken` and `refreshToken` directly to put the session in the state it needs; that
/// is not a write by the refresher and is not recorded.
///
/// nonisolated: Swift 6.4 would make a class that conforms to these MainActor-isolated protocols MainActor-isolated, but
/// the refresher reads and writes from its own task while the test changes the tokens, which the lock makes safe.
nonisolated private final class RecordingTokenStores: APIAccessTokenStore, APIRefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAccessToken: String?
    private var storedRefreshToken: String?
    private var recorded: [String] = []
    private var failingAccessSave: (any Error)?
    private var failingRefreshSave: (any Error)?

    var accessToken: String? {
        get { lock.withLock { storedAccessToken } }
        set { lock.withLock { storedAccessToken = newValue } }
    }

    var refreshToken: String? {
        get { lock.withLock { storedRefreshToken } }
        set { lock.withLock { storedRefreshToken = newValue } }
    }

    /// The writes made through the store protocols, in order: "access" and "refresh" for a save, "clear access" and
    /// "clear refresh" for a clear. A save that throws is not recorded: it wrote nothing.
    var events: [String] { lock.withLock { recorded } }

    var accessSaveError: (any Error)? {
        get { lock.withLock { failingAccessSave } }
        set { lock.withLock { failingAccessSave = newValue } }
    }

    var refreshSaveError: (any Error)? {
        get { lock.withLock { failingRefreshSave } }
        set { lock.withLock { failingRefreshSave = newValue } }
    }

    func loadAccessToken() -> String? { accessToken }

    func saveAccessToken(_ token: String) throws {
        try lock.withLock {
            if let failingAccessSave { throw failingAccessSave }
            storedAccessToken = token
            recorded.append("access")
        }
    }

    func clearAccessToken() throws {
        lock.withLock {
            storedAccessToken = nil
            recorded.append("clear access")
        }
    }

    func loadRefreshToken() -> String? { refreshToken }

    func saveRefreshToken(_ token: String) throws {
        try lock.withLock {
            if let failingRefreshSave { throw failingRefreshSave }
            storedRefreshToken = token
            recorded.append("refresh")
        }
    }

    func clearRefreshToken() throws {
        lock.withLock {
            storedRefreshToken = nil
            recorded.append("clear refresh")
        }
    }
}
