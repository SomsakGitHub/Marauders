//
//  LikesAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct LikesAPIClientTests {
    private static let authorization = LikesTestAuthorization()
    private static let videoID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private static func session(
        status: Int = 200,
        body: String = #"{"liked":true,"likeCount":4}"#,
        capture: ((URLRequest) -> Void)? = nil
    ) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    @Test func likingSendsAPutWithTheSessionAndDecodesTheAnswer() async throws {
        var captured: URLRequest?
        let session = Self.session { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let state = try await LikesAPIClient(session: session, authorization: Self.authorization)
            .setLiked(true, videoID: Self.videoID)

        #expect(state == ClipLikeState(liked: true, count: 4))
        #expect(captured?.httpMethod == "PUT")
        #expect(captured?.url?.path().hasSuffix("/v1/videos/\(Self.videoID.uuidString)/like") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func takingTheLikeBackSendsADelete() async throws {
        var captured: URLRequest?
        let session = Self.session(body: #"{"liked":false,"likeCount":3}"#) { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let state = try await LikesAPIClient(session: session, authorization: Self.authorization)
            .setLiked(false, videoID: Self.videoID)

        #expect(state == ClipLikeState(liked: false, count: 3))
        #expect(captured?.httpMethod == "DELETE")
        #expect(captured?.url?.path().hasSuffix("/v1/videos/\(Self.videoID.uuidString)/like") == true)
    }

    @Test func aGuestNeverSendsARequest() async {
        var requestCount = 0
        let session = Self.session { _ in requestCount += 1 }
        defer { StubURLSessionFactory.reset(session) }

        let client = LikesAPIClient(session: session, authorization: nil)
        await #expect(throws: ClipLikeError.signInRequired) {
            try await client.setLiked(true, videoID: Self.videoID)
        }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, ClipLikeError.signInRequired),
        (404, ClipLikeError.notFound),
        (429, ClipLikeError.rateLimited),
        (400, ClipLikeError.serverError(400)),
        (500, ClipLikeError.serverError(500)),
    ])
    func mapsStatusCodes(statusCode: Int, expected: ClipLikeError) async {
        let session = Self.session(status: statusCode, body: "")
        defer { StubURLSessionFactory.reset(session) }

        let client = LikesAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) {
            try await client.setLiked(true, videoID: Self.videoID)
        }
    }

    @Test(arguments: ["", "not json", #"{"liked":true}"#, #"{"likeCount":2}"#])
    func anAnswerThatIsNotAStateIsInvalid(body: String) async {
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let client = LikesAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: ClipLikeError.invalidResponse) {
            try await client.setLiked(true, videoID: Self.videoID)
        }
    }

    @Test func aNegativeCountIsShownAsZero() async throws {
        let session = Self.session(body: #"{"liked":false,"likeCount":-2}"#)
        defer { StubURLSessionFactory.reset(session) }

        let state = try await LikesAPIClient(session: session, authorization: Self.authorization)
            .setLiked(false, videoID: Self.videoID)

        #expect(state.count == 0)
    }
}

private struct LikesTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
