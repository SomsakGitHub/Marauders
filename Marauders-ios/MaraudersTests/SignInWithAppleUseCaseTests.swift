//
//  SignInWithAppleUseCaseTests.swift
//  MaraudersTests
//

import Testing

@testable import Marauders

@MainActor
struct SignInWithAppleUseCaseTests {
    @Test func keepsTheUserAndTheAccessTokenTheWorkerGave() async throws {
        let worker = WorkerSpy(returning: "token-from-the-worker")
        let sessions = SessionStoreSpy()
        let tokens = TokenStoreSpy()
        let signIn = SignInWithAppleUseCase(authAPI: worker, sessionStore: sessions, tokenStore: tokens)

        try await signIn.execute(
            userID: "001234.abcdef.5678", identityToken: "identity-token-from-apple", countryCode: "JP")

        #expect(worker.calls == [.init(identityToken: "identity-token-from-apple", countryCode: "JP")])
        #expect(sessions.savedUserID == "001234.abcdef.5678")
        #expect(tokens.savedToken == "token-from-the-worker")
    }

    @Test func refusesAnInvalidAccountBeforeAskingTheWorker() async {
        let worker = WorkerSpy(returning: "token-from-the-worker")
        let sessions = SessionStoreSpy()
        let tokens = TokenStoreSpy()
        let signIn = SignInWithAppleUseCase(authAPI: worker, sessionStore: sessions, tokenStore: tokens)

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
        let signIn = SignInWithAppleUseCase(authAPI: worker, sessionStore: sessions, tokenStore: tokens)

        await #expect(throws: AuthAPIError.serverError(503)) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }

        #expect(worker.calls.count == 1)
        #expect(sessions.savedUserID == nil)
        #expect(tokens.savedToken == nil)
    }

    @Test func reportsAnAccessTokenThatCouldNotBeKept() async {
        let tokens = TokenStoreSpy()
        tokens.failure = StoreFailure()
        let signIn = SignInWithAppleUseCase(
            authAPI: WorkerSpy(returning: "token-from-the-worker"), sessionStore: SessionStoreSpy(), tokenStore: tokens)

        await #expect(throws: StoreFailure()) {
            try await signIn.execute(userID: "user-1", identityToken: "identity-token-from-apple", countryCode: "JP")
        }
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
        @Test func becomesTheNamedUserWithTheTokenTheWorkerGave() async throws {
            let worker = DevWorkerSpy(returning: "dev-token-from-the-worker")
            let sessions = SessionStoreSpy()
            let tokens = TokenStoreSpy()
            let signIn = SignInAsDevUserUseCase(devAuth: worker, sessionStore: sessions, tokenStore: tokens)

            try await signIn.execute(secret: "shared-secret", label: "alice", userID: "dev-alice", countryCode: "NL")

            #expect(worker.calls == [.init(secret: "shared-secret", label: "alice", countryCode: "NL")])
            #expect(sessions.savedUserID == "dev-alice")
            #expect(tokens.savedToken == "dev-token-from-the-worker")
        }

        @Test func savesNothingWhenTheWorkerRefuses() async {
            let worker = DevWorkerSpy(throwing: .serverError(401))
            let sessions = SessionStoreSpy()
            let tokens = TokenStoreSpy()
            let signIn = SignInAsDevUserUseCase(devAuth: worker, sessionStore: sessions, tokenStore: tokens)

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

        private let outcome: Result<String, AuthAPIError>
        private(set) var calls: [Call] = []

        init(returning token: String) { outcome = .success(token) }
        init(throwing error: AuthAPIError) { outcome = .failure(error) }

        func accessToken(secret: String, label: String, countryCode: String) async throws -> String {
            calls.append(Call(secret: secret, label: label, countryCode: countryCode))
            return try outcome.get()
        }
    }
#endif

/// Answers the sign-in exchange with a fixed token or error, and remembers what it was asked.
private final class WorkerSpy: AuthAPIClientProtocol, @unchecked Sendable {
    struct Call: Equatable {
        let identityToken: String
        let countryCode: String
    }

    private let outcome: Result<String, AuthAPIError>
    private(set) var calls: [Call] = []

    init(returning token: String) { outcome = .success(token) }
    init(throwing error: AuthAPIError) { outcome = .failure(error) }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> String {
        calls.append(Call(identityToken: identityToken, countryCode: countryCode))
        return try outcome.get()
    }
}

private final class SessionStoreSpy: AuthSessionStore, @unchecked Sendable {
    private(set) var savedUserID: String?

    func loadUserID() -> String? { savedUserID }
    func saveUserID(_ userID: String) throws { savedUserID = userID }
    func clear() throws { savedUserID = nil }
}

private struct StoreFailure: Error, Equatable {}

private final class TokenStoreSpy: APIAccessTokenStore, @unchecked Sendable {
    private(set) var savedToken: String?
    /// When set, saving throws it and keeps nothing.
    var failure: Error?

    func loadAccessToken() -> String? { savedToken }

    func saveAccessToken(_ token: String) throws {
        if let failure { throw failure }
        savedToken = token
    }

    func clearAccessToken() throws { savedToken = nil }
}
