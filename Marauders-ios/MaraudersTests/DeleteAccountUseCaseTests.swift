//
//  DeleteAccountUseCaseTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// Deleting an account asks the Worker first and clears the feed this iPhone kept only once the Worker said yes.
@Suite(.serialized)
@MainActor
struct DeleteAccountUseCaseTests {
    @Test func theRepositoryIsAskedOnceWithTheCodeAndThenTheCacheIsCleared() async throws {
        let journal = DeletionJournal()
        let useCase = DeleteAccountUseCase(
            repository: RecordingDeletionRepository(journal: journal),
            feedCache: RecordingFeedCache(journal: journal)
        )

        try await useCase.execute(authorizationCode: "code-123")

        #expect(journal.events == ["delete code-123", "removeAll"])
    }

    @Test func noCodeIsPassedOnAsNoCode() async throws {
        let journal = DeletionJournal()
        let useCase = DeleteAccountUseCase(
            repository: RecordingDeletionRepository(journal: journal),
            feedCache: RecordingFeedCache(journal: journal)
        )

        try await useCase.execute(authorizationCode: nil)

        #expect(journal.events == ["delete none", "removeAll"])
    }

    /// A deletion that failed leaves the account, so the feed it saved must stay for the next try.
    @Test func aFailureOfTheRepositoryReachesTheCallerAndTheCacheIsLeftAlone() async {
        let journal = DeletionJournal()
        let repository = RecordingDeletionRepository(journal: journal)
        repository.failure = AccountDeletionError.wrongAppleAccount
        let useCase = DeleteAccountUseCase(repository: repository, feedCache: RecordingFeedCache(journal: journal))

        await #expect(throws: AccountDeletionError.wrongAppleAccount) {
            try await useCase.execute(authorizationCode: "code-123")
        }

        #expect(journal.events == ["delete code-123"], "removeAll() never ran")
    }

    @Test func noCacheIsNoProblem() async throws {
        let journal = DeletionJournal()
        let useCase = DeleteAccountUseCase(
            repository: RecordingDeletionRepository(journal: journal), feedCache: nil)

        try await useCase.execute(authorizationCode: "code-123")

        #expect(journal.events == ["delete code-123"])
    }

    @Test func theDefaultRepositoryHandsTheCodeToTheAPIClient() async throws {
        var capturedBody: Data?
        let session = StubURLSessionFactory.make { request in
            capturedBody = request.readBody()
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 204), Data())
        }
        defer { StubURLSessionFactory.reset(session) }
        let repository = DefaultAccountDeletionRepository(
            apiClient: AccountDeletionAPIClient(session: session, authorization: UseCaseTestAuthorization()))

        try await repository.deleteAccount(authorizationCode: "code-123")

        let sent = try JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: String]
        #expect(sent == ["authorizationCode": "code-123"])
    }

    /// The UI tests need a deletion that ends: after a short wait, so the progress shows, and either well or badly.
    @Test func theUITestRepositoryWaitsAMomentAndSucceeds() async throws {
        let clock = ContinuousClock()
        let started = clock.now

        try await UITestAccountDeletionRepository(fails: false).deleteAccount(authorizationCode: "any")

        #expect(clock.now - started >= .milliseconds(250), "long enough for the progress to be on screen")
    }

    @Test func theUITestRepositoryCanFail() async {
        let repository = UITestAccountDeletionRepository(fails: true)

        await #expect(throws: AccountDeletionError.couldNotFinish) {
            try await repository.deleteAccount(authorizationCode: "any")
        }
    }
}

/// What the doubles were asked, in order.
private final class DeletionJournal: @unchecked Sendable {
    var events: [String] = []
}

private final class RecordingDeletionRepository: AccountDeletionRepository, @unchecked Sendable {
    private let journal: DeletionJournal
    var failure: Error?

    init(journal: DeletionJournal) {
        self.journal = journal
    }

    func deleteAccount(authorizationCode: String?) async throws {
        journal.events.append("delete \(authorizationCode ?? "none")")
        if let failure { throw failure }
    }
}

private final class RecordingFeedCache: FeedStartupCacheClearing, @unchecked Sendable {
    private let journal: DeletionJournal

    init(journal: DeletionJournal) {
        self.journal = journal
    }

    func removeAll() async {
        journal.events.append("removeAll")
    }
}

private struct UseCaseTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
