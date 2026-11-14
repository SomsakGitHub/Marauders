//
//  FollowListAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct FollowListAPIClientTests {
    private static let authorization = FollowListTestAuthorization()

    private static let pagePayload = """
        {
          "items": [
            {"handle": "@bob", "avatarURL": "https://example.com/bob.jpg", "followedByViewer": true, "isViewer": false},
            {"handle": "@me", "avatarURL": null, "followedByViewer": false, "isViewer": true}
          ],
          "nextCursor": "abc_-1"
        }
        """

    private static func session(
        status: Int = 200,
        body: String = pagePayload,
        capture: ((URLRequest) -> Void)? = nil
    ) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    /// The query of a captured request, name to value.
    private static func query(of request: URLRequest?) -> [String: String?] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    }

    @Test func fetchingFollowersSendsAGetWithTheSessionAndDecodesThePage() async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let page = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)

        let bob = FollowListEntry(
            handle: "@bob",
            avatarURL: URL(string: "https://example.com/bob.jpg"),
            followedByViewer: true,
            isViewer: false
        )
        let me = FollowListEntry(handle: "@me", avatarURL: nil, followedByViewer: false, isViewer: true)
        #expect(page == FollowListPage(entries: [bob, me], nextCursor: "abc_-1"))
        #expect(captured?.httpMethod == "GET")
        #expect(captured?.url?.path().hasSuffix("/v1/users/@alice/followers") == true)
        #expect(Self.query(of: captured) == ["limit": "30"])
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(captured?.timeoutInterval == 15)
    }

    @Test func followingUsesItsOwnPath() async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        _ = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .following, cursor: nil, limit: 30)

        #expect(captured?.url?.path().hasSuffix("/v1/users/@alice/following") == true)
    }

    @Test func aCursorGoesInTheQuery() async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }
        let cursor = "MjAyNi0xMS0wMVQxMDozNDozMC4wMDMxMjNafEBhbGljZQ"

        _ = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .followers, cursor: cursor, limit: 10)

        #expect(Self.query(of: captured) == ["limit": "10", "cursor": cursor])
    }

    @Test(arguments: [(0, "1"), (1, "1"), (50, "50"), (500, "50")])
    func theLimitStaysBetweenOneAndFifty(asked: Int, sent: String) async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        _ = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: asked)

        #expect(Self.query(of: captured)["limit"] == sent)
    }

    @Test func aGuestNeverSendsARequest() async {
        var requestCount = 0
        let session = Self.session { _ in requestCount += 1 }
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowListAPIClient(session: session, authorization: nil)
        await #expect(throws: FollowListError.signInRequired) {
            try await client.fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)
        }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, FollowListError.signInRequired),
        (404, FollowListError.notFound),
        (429, FollowListError.rateLimited),
        (400, FollowListError.serverError(400)),
        (405, FollowListError.serverError(405)),
        (500, FollowListError.serverError(500)),
    ])
    func mapsStatusCodes(statusCode: Int, expected: FollowListError) async {
        let session = Self.session(status: statusCode, body: "")
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowListAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) {
            try await client.fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)
        }
    }

    @Test(arguments: [
        "",
        "not json",
        "{}",
        #"{"items":[{"handle":"@bob"}]}"#,
        #"{"items":[{"handle":"@bob","avatarURL":null,"followedByViewer":false}]}"#,
        #"{"items":[{"handle":"@bob","avatarURL":null,"isViewer":false}]}"#,
        #"{"items":[{"avatarURL":null,"followedByViewer":false,"isViewer":false}]}"#,
    ])
    func anAnswerThatIsNotAPageIsInvalid(body: String) async {
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let client = FollowListAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: FollowListError.invalidResponse) {
            try await client.fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)
        }
    }

    @Test(
        arguments: [
            ("null", nil),
            (#""""#, nil),
            (#""not a url""#, nil),
            (#""/relative.jpg""#, nil),
            (#""ftp://example.com/a.jpg""#, nil),
            (#""https://example.com/a.jpg""#, "https://example.com/a.jpg"),
        ] as [(String, String?)])
    func anAvatarThatIsMissingOrNotAnAddressShowsThePlaceholder(avatar: String, expected: String?) async throws {
        let body = """
            {"items": [
              {"handle": "@bob", "avatarURL": \(avatar), "followedByViewer": false, "isViewer": false},
              {"handle": "@carol", "avatarURL": "https://example.com/carol.jpg", "followedByViewer": true, "isViewer": false}
            ], "nextCursor": null}
            """
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let page = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)

        // One bad address costs that row its picture, never the page.
        #expect(page.entries.map(\.handle) == ["@bob", "@carol"])
        #expect(page.entries.first?.avatarURL == expected.flatMap { URL(string: $0) })
        #expect(page.entries.last?.avatarURL == URL(string: "https://example.com/carol.jpg"))
    }

    @Test(arguments: [#"{"items":[],"nextCursor":null}"#, #"{"items":[]}"#])
    func aPageWithoutNextCursorEndsTheList(body: String) async throws {
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let page = try await FollowListAPIClient(session: session, authorization: Self.authorization)
            .fetchList(handle: "@alice", kind: .followers, cursor: nil, limit: 30)

        #expect(page == FollowListPage(entries: [], nextCursor: nil))
    }
}

private struct FollowListTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
