//
//  FollowListUseCaseTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct FollowListUseCaseTests {
    private static let bob = FollowListEntry(handle: "@bob", avatarURL: nil, followedByViewer: true, isViewer: false)

    @Test func theUseCaseAsksForTheFirstPageOfThirtyByDefault() async throws {
        let stub = StubFollowListRepository(fetchResults: [.success(FollowListPage(entries: [Self.bob], nextCursor: "next"))])

        let page = try await LoadFollowListUseCase(repository: stub).execute(handle: "@alice", kind: .followers)

        #expect(page == FollowListPage(entries: [Self.bob], nextCursor: "next"))
        #expect(stub.fetches.count == 1)
        #expect(stub.fetches.first?.handle == "@alice")
        #expect(stub.fetches.first?.kind == .followers)
        #expect(stub.fetches.first?.cursor == nil)
        #expect(stub.fetches.first?.limit == FollowListRules.pageSize)
        #expect(FollowListRules.pageSize == 30)
    }

    @Test func theUseCaseForwardsTheCursorAndLimit() async throws {
        let stub = StubFollowListRepository()

        _ = try await LoadFollowListUseCase(repository: stub)
            .execute(handle: "@alice", kind: .following, cursor: "abc", limit: 7)

        #expect(stub.fetches.count == 1)
        #expect(stub.fetches.first?.kind == .following)
        #expect(stub.fetches.first?.cursor == "abc")
        #expect(stub.fetches.first?.limit == 7)
    }

    @Test func theDefaultRepositoryReturnsWhatTheClientDecoded() async throws {
        let session = StubURLSessionFactory.make { request in
            let body = #"{"items":[{"handle":"@bob","avatarURL":null,"followedByViewer":true,"isViewer":false}],"nextCursor":null}"#
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(body.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = FollowListAPIClient(session: session, authorization: FollowListUseCaseTestAuthorization())

        let page = try await DefaultFollowListRepository(apiClient: client)
            .fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)

        #expect(page == FollowListPage(entries: [Self.bob], nextCursor: nil))
    }

    @Test func anEntryIsIdentifiedByItsNormalizedHandle() {
        let shouting = FollowListEntry(handle: "@Bob", avatarURL: nil, followedByViewer: false, isViewer: false)
        #expect(shouting.id == "@bob")
        #expect(shouting.id == Self.bob.id)
    }

    @Test func theErrorsReadAsPlainSentences() {
        #expect(FollowListError.signInRequired.errorDescription == "Sign in required")
        #expect(FollowListError.notFound.errorDescription == "Profile not found")
        #expect(FollowListError.rateLimited.errorDescription == "Too many requests, try again shortly")
        #expect(FollowListError.invalidResponse.errorDescription == "Invalid server response")
        #expect(FollowListError.serverError(502).errorDescription == "Server responded with status 502")
    }

    @Test func theWorkersPathComponentIsTheRawValue() {
        #expect(FollowListKind.followers.rawValue == "followers")
        #expect(FollowListKind.following.rawValue == "following")
        #expect(FollowListKind.allCases == [.followers, .following])
    }
}

private struct FollowListUseCaseTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
