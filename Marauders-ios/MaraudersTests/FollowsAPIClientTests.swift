//
//  FollowsAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct FollowsAPIClientTests {
    private static let authorization = FollowsTestAuthorization()

    private static func session(
        status: Int = 200,
        body: String = #"{"following":true,"followerCount":4,"viewerFollowingCount":9}"#,
        capture: ((URLRequest) -> Void)? = nil
    ) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    @Test func followingSendsAPutWithTheSessionAndDecodesTheAnswer() async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let change = try await FollowsAPIClient(session: session, authorization: Self.authorization)
            .setFollowing(true, handle: "@alice")

        #expect(change == UserFollowChange(following: true, followerCount: 4, viewerFollowingCount: 9))
        #expect(captured?.httpMethod == "PUT")
        #expect(captured?.url?.path().hasSuffix("/v1/users/@alice/follow") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func stoppingAFollowSendsADelete() async throws {
        var captured: URLRequest?
        let session = Self.session(body: #"{"following":false,"followerCount":3,"viewerFollowingCount":8}"#) {
            captured = $0
        }
        defer { StubURLSessionFactory.reset(session) }

        let change = try await FollowsAPIClient(session: session, authorization: Self.authorization)
            .setFollowing(false, handle: "@alice")

        #expect(change == UserFollowChange(following: false, followerCount: 3, viewerFollowingCount: 8))
        #expect(captured?.httpMethod == "DELETE")
        #expect(captured?.url?.path().hasSuffix("/v1/users/@alice/follow") == true)
    }

    @Test func aGuestNeverSendsARequest() async {
        var requestCount = 0
        let session = Self.session { _ in requestCount += 1 }
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowsAPIClient(session: session, authorization: nil)
        await #expect(throws: UserFollowError.signInRequired) {
            try await client.setFollowing(true, handle: "@alice")
        }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, UserFollowError.signInRequired),
        (404, UserFollowError.notFound),
        (400, UserFollowError.notFound),
        (422, UserFollowError.cannotFollowSelf),
        (429, UserFollowError.rateLimited),
        (405, UserFollowError.serverError(405)),
        (500, UserFollowError.serverError(500)),
    ])
    func mapsStatusCodes(statusCode: Int, expected: UserFollowError) async {
        let session = Self.session(status: statusCode, body: "")
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) {
            try await client.setFollowing(true, handle: "@alice")
        }
    }

    @Test(arguments: ["", "not json", #"{"following":true}"#, #"{"following":true,"followerCount":2}"#])
    func anAnswerThatIsNotAChangeIsInvalid(body: String) async {
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserFollowError.invalidResponse) {
            try await client.setFollowing(true, handle: "@alice")
        }
    }

    @Test func negativeCountsAreShownAsZero() async throws {
        let session = Self.session(body: #"{"following":false,"followerCount":-2,"viewerFollowingCount":-1}"#)
        defer { StubURLSessionFactory.reset(session) }

        let change = try await FollowsAPIClient(session: session, authorization: Self.authorization)
            .setFollowing(false, handle: "@alice")

        #expect(change.followerCount == 0)
        #expect(change.viewerFollowingCount == 0)
    }
}

private struct FollowsTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
