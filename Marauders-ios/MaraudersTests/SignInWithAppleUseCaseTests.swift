//
//  SignInWithAppleUseCaseTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders
@testable import MaraudersAuth

@MainActor
struct SignInWithAppleUseCaseTests {
    private static let refreshToken = "refresh-token-from-the-worker"

    private func makeUseCase(
        worker: WorkerSpy,
        sessions: SessionStoreSpy = SessionStoreSpy(),
        tokens: TokenStoreSpy = TokenStoreSpy(),
        refresh: RefreshStoreSpy = RefreshStoreSpy()
    ) -> SignInWithAppleUseCase {
        SignInWithAppleUseCase(
            authAPI: worker, sessionStore: sessions, tokenStore: tokens, refreshTokenStore: refresh)
    }

    @Test func keepsTheUserAndTheAccessTokenTheWorkerGave() async throws {
        let worker = WorkerSpy(returning: "token-from-the-worker")
        let sessions = SessionStoreSpy()
        let tokens = TokenStoreSpy()
        let signIn = makeUseCase(worker: worker, sessions: sessions, tokens: tokens)

        try await signIn.execute(
            userID: "001234.abcdef.5678", identityToken: "identity-token-from-apple", countryCode: "JP")

        #expect(worker.calls == [.init(identityToken: "identity-token-from-apple", countryCode: "JP")])
        #expect(sessions.savedUserID == "001234.abcdef.5678")
        #expect(tokens.savedToken == "token-from-the-worker")
    }

    /// The access token comes last: a session is live once it is stored, so everything it depends on is in place first.
    @Test func signingInSavesTheUserThenTheRefreshTokenThenTheAccessToken() async throws {
        let log = EventLog()
        let worker = WorkerSpy(
            returning: AuthTokens(accessToken: "token-from-the-worker", refreshToken: Self.refreshToken))
        let refresh = RefreshStoreSpy(log: log)
        let signIn = makeUseCase(
            worker: worker, sessions: SessionStoreSpy(log: log), tokens: TokenStoreSpy(log: log), refresh: refresh)

        try await signIn.execute(
            userID: "001234.abcdef.5678", identityToken: "identity-token-from-apple", countryCode: "JP")

        #expect(log.events == ["user", "refresh", "access"])
        #expect(refresh.token == Self.refreshToken)
    }

    @Test func anAnswerWithoutARefreshTokenClearsAStaleOne() async throws {
        let log = EventLog()
        let refresh = RefreshStoreSpy(log: log, token: "refresh-token-of-an-earlier-session")
        let signIn = makeUseCase(
            worker: WorkerSpy(returning: "token-from-the-worker"),
            sessions: SessionStoreSpy(log: log), tokens: TokenStoreSpy(log: log), refresh: refresh)

        try await signIn.execute(
            userID: "001234.abcdef.5678", identityToken: "identity-token-from-apple", countryCode: "JP")

        #expect(refresh.token == nil)
        #expect(log.events == ["user", "refresh cleared", "access"])
    }

    @Test func refusesAnInvalidAccountBeforeAskingTheWorker() async {
        let worker = WorkerSpy(returning: "token-from-the-worker")
        let sessions = SessionStoreSpy()
        let tokens = TokenStoreSpy()
        let signIn = makeUseCase(worker: worker, sessions: sessions, tokens: tokens)

        await #expect(throws: SignInError.invalidAccount) {
            try await signIn.execute(userID: "   ", identityToken: "identity-token-from-apple", countryCode: "JP")
        }

        #expect(worker.calls.isEmpty)
        #expect(sessions.savedUserID == nil)
        #expect(tokens.savedToken == nil)
    }

    @Test func savesNothingAndPassesTheErrorOnWhenTheWorkerRefuses() async {
        let worker = WorkerSpy(throwing: .serverError(503))
        let sessions = SessionStoreSpy()
        let tokens = TokenStoreSpy()
        let refresh = RefreshStoreSpy(token: "refresh-token-of-an-earlier-session")
        let signIn = makeUseCase(worker: worker, sessions: sessions, tokens: tokens, refresh: refresh)

        await #expect(throws: AuthAPIError.serverError(503)) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }

        #expect(worker.calls.count == 1)
        #expect(sessions.savedUserID == nil)
        #expect(tokens.savedToken == nil)
        #expect(refresh.token == "refresh-token-of-an-earlier-session", "a refused sign-in changes nothing")
    }

    @Test func reportsAnAccessTokenThatCouldNotBeKept() async {
        let tokens = TokenStoreSpy()
        tokens.failure = StoreFailure()
        let signIn = makeUseCase(worker: WorkerSpy(returning: "token-from-the-worker"), tokens: tokens)

        await #expect(throws: StoreFailure()) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }
    }

    /// A save that fails stops the sign-in there: nothing that comes after it is saved, so a half-made session never
    /// looks live.
    @Test func aRefreshTokenThatCouldNotBeKeptLeavesNoNewerAccessToken() async {
        let log = EventLog()
        let refresh = RefreshStoreSpy(log: log)
        refresh.failure = StoreFailure()
        let tokens = TokenStoreSpy(log: log)
        let signIn = makeUseCase(
            worker: WorkerSpy(
                returning: AuthTokens(accessToken: "token-from-the-worker", refreshToken: Self.refreshToken)),
            sessions: SessionStoreSpy(log: log), tokens: tokens, refresh: refresh)

        await #expect(throws: StoreFailure()) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }

        #expect(log.events == ["user"])
        #expect(tokens.savedToken == nil)
    }

    @Test func aStaleRefreshTokenThatCouldNotBeClearedLeavesNoNewerAccessToken() async {
        let log = EventLog()
        let refresh = RefreshStoreSpy(log: log, token: "refresh-token-of-an-earlier-session")
        refresh.failure = StoreFailure()
        let tokens = TokenStoreSpy(log: log)
        let signIn = makeUseCase(
            worker: WorkerSpy(returning: "token-from-the-worker"),
            sessions: SessionStoreSpy(log: log), tokens: tokens, refresh: refresh)

        await #expect(throws: StoreFailure()) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }

        #expect(log.events == ["user"])
        #expect(tokens.savedToken == nil)
    }
}

@MainActor
struct AuthUserIDTests {
    @Test(arguments: ["001234.abcdef.5678", "user-1", String(repeating: "a", count: 512)])
    func acceptsAnIdentifierAppleCouldIssue(userID: String) {
        #expect(AuthUserID.isValid(userID))
    }

    @Test(arguments: ["", "   ", " \n ", "abc\u{0007}def", "abc\ndef", String(repeating: "a", count: 513)])
    func rejectsAnEmptyOverlongOrControlCharacterIdentifier(userID: String) {
        #expect(!AuthUserID.isValid(userID))
    }
}

#if DEBUG
    @MainActor
    struct SignInAsDevUserUseCaseTests {
        private func makeUseCase(
            worker: DevWorkerSpy,
            sessions: SessionStoreSpy = SessionStoreSpy(),
            tokens: TokenStoreSpy = TokenStoreSpy(),
            refresh: RefreshStoreSpy = RefreshStoreSpy()
        ) -> SignInAsDevUserUseCase {
            SignInAsDevUserUseCase(
                devAuth: worker, sessionStore: sessions, tokenStore: tokens, refreshTokenStore: refresh)
        }

        @Test func becomesTheNamedUserWithTheTokenTheWorkerGave() async throws {
            let worker = DevWorkerSpy(returning: "dev-token-from-the-worker")
            let sessions = SessionStoreSpy()
            let tokens = TokenStoreSpy()
            let signIn = makeUseCase(worker: worker, sessions: sessions, tokens: tokens)

            try await signIn.execute(secret: "shared-secret", label: "alice", userID: "dev-alice", countryCode: "NL")

            #expect(worker.calls == [.init(secret: "shared-secret", label: "alice", countryCode: "NL")])
            #expect(sessions.savedUserID == "dev-alice")
            #expect(tokens.savedToken == "dev-token-from-the-worker")
        }

        @Test func signingInSavesTheUserThenTheRefreshTokenThenTheAccessToken() async throws {
            let log = EventLog()
            let worker = DevWorkerSpy(
                returning: AuthTokens(
                    accessToken: "dev-token-from-the-worker", refreshToken: "dev-refresh-token-from-the-worker"))
            let refresh = RefreshStoreSpy(log: log)
            let signIn = makeUseCase(
                worker: worker, sessions: SessionStoreSpy(log: log), tokens: TokenStoreSpy(log: log), refresh: refresh)

            try await signIn.execute(secret: "shared-secret", label: "alice", userID: "dev-alice", countryCode: "NL")

            #expect(log.events == ["user", "refresh", "access"])
            #expect(refresh.token == "dev-refresh-token-from-the-worker")
        }

        @Test func anAnswerWithoutARefreshTokenClearsAStaleOne() async throws {
            let log = EventLog()
            let refresh = RefreshStoreSpy(log: log, token: "refresh-token-of-an-earlier-session")
            let signIn = makeUseCase(
                worker: DevWorkerSpy(returning: "dev-token-from-the-worker"),
                sessions: SessionStoreSpy(log: log), tokens: TokenStoreSpy(log: log), refresh: refresh)

            try await signIn.execute(secret: "shared-secret", label: "alice", userID: "dev-alice", countryCode: "NL")

            #expect(refresh.token == nil)
            #expect(log.events == ["user", "refresh cleared", "access"])
        }

        @Test func aRefreshTokenThatCouldNotBeKeptLeavesNoNewerAccessToken() async {
            let log = EventLog()
            let refresh = RefreshStoreSpy(log: log)
            refresh.failure = StoreFailure()
            let tokens = TokenStoreSpy(log: log)
            let signIn = makeUseCase(
                worker: DevWorkerSpy(
                    returning: AuthTokens(
                        accessToken: "dev-token-from-the-worker", refreshToken: "dev-refresh-token-from-the-worker")),
                sessions: SessionStoreSpy(log: log), tokens: tokens, refresh: refresh)

            await #expect(throws: StoreFailure()) {
                try await signIn.execute(
                    secret: "shared-secret", label: "alice", userID: "dev-alice", countryCode: "NL")
            }

            #expect(log.events == ["user"])
            #expect(tokens.savedToken == nil)
        }

        @Test func savesNothingWhenTheWorkerRefuses() async {
            let worker = DevWorkerSpy(throwing: .serverError(401))
            let sessions = SessionStoreSpy()
            let tokens = TokenStoreSpy()
            let signIn = makeUseCase(worker: worker, sessions: sessions, tokens: tokens)

            await #expect(throws: AuthAPIError.serverError(401)) {
                try await signIn.execute(secret: "wrong", label: "alice", userID: "dev-alice", countryCode: "NL")
            }

            #expect(sessions.savedUserID == nil)
            #expect(tokens.savedToken == nil)
        }
    }

    private final class DevWorkerSpy: DevAuthExchanging, @unchecked Sendable {
        struct Call: Equatable {
            let secret: String
            let label: String
            let countryCode: String
        }

        private let outcome: Result<AuthTokens, AuthAPIError>
        private(set) var calls: [Call] = []

        init(returning token: String) { outcome = .success(AuthTokens(accessToken: token, refreshToken: nil)) }
        init(returning tokens: AuthTokens) { outcome = .success(tokens) }
        init(throwing error: AuthAPIError) { outcome = .failure(error) }

        func tokens(secret: String, label: String, countryCode: String) async throws -> AuthTokens {
            calls.append(Call(secret: secret, label: label, countryCode: countryCode))
            return try outcome.get()
        }
    }
#endif

/// Answers the sign-in exchange with a fixed pair or error, and remembers what it was asked.
private final class WorkerSpy: AuthAPIClientProtocol, @unchecked Sendable {
    struct Call: Equatable {
        let identityToken: String
        let countryCode: String
    }

    private let outcome: Result<AuthTokens, AuthAPIError>
    private(set) var calls: [Call] = []

    init(returning token: String) { outcome = .success(AuthTokens(accessToken: token, refreshToken: nil)) }
    init(returning tokens: AuthTokens) { outcome = .success(tokens) }
    init(throwing error: AuthAPIError) { outcome = .failure(error) }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        calls.append(Call(identityToken: identityToken, countryCode: countryCode))
        return try outcome.get()
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

/// The order in which the three stores were written, across all of them.
private final class EventLog: @unchecked Sendable {
    private(set) var events: [String] = []

    func record(_ event: String) { events.append(event) }
}

private final class SessionStoreSpy: AuthSessionStore, @unchecked Sendable {
    private let log: EventLog
    private(set) var savedUserID: String?

    init(log: EventLog = EventLog()) { self.log = log }

    func loadUserID() -> String? { savedUserID }

    func saveUserID(_ userID: String) throws {
        savedUserID = userID
        log.record("user")
    }

    func clear() throws { savedUserID = nil }
}

private struct StoreFailure: Error, Equatable {}

private final class TokenStoreSpy: APIAccessTokenStore, @unchecked Sendable {
    private let log: EventLog
    private(set) var savedToken: String?
    /// When set, saving throws it and keeps nothing.
    var failure: Error?

    init(log: EventLog = EventLog()) { self.log = log }

    func loadAccessToken() -> String? { savedToken }

    func saveAccessToken(_ token: String) throws {
        if let failure { throw failure }
        savedToken = token
        log.record("access")
    }

    func clearAccessToken() throws { savedToken = nil }
}

private final class RefreshStoreSpy: APIRefreshTokenStore, @unchecked Sendable {
    private let log: EventLog
    private(set) var token: String?
    /// When set, saving and clearing throw it and change nothing.
    var failure: Error?

    init(log: EventLog = EventLog(), token: String? = nil) {
        self.log = log
        self.token = token
    }

    func loadRefreshToken() -> String? { token }

    func saveRefreshToken(_ token: String) throws {
        if let failure { throw failure }
        self.token = token
        log.record("refresh")
    }

    func clearRefreshToken() throws {
        if let failure { throw failure }
        token = nil
        log.record("refresh cleared")
    }
}
