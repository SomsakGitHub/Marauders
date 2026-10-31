//
//  CommentsAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct CommentsAPIClientTests {
    private static let authorization = CommentsTestAuthorization()
    private static let videoID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let commentID = UUID(uuidString: "66666666-7777-4888-9999-000000000000")!

    private static let listPayload = """
    {
      "items": [
        {
          "id": "11111111-2222-4333-8444-555555555555",
          "body": "Nice view",
          "language": "th",
          "createdAt": "2026-10-30T12:34:56.789Z",
          "authorName": "@friend",
          "authorAvatarURL": "https://example.com/a.jpg",
          "canDelete": false
        },
        {
          "id": "66666666-7777-4888-9999-000000000000",
          "body": "Mine",
          "language": null,
          "createdAt": "2026-10-30T12:00:00.000Z",
          "authorName": "@me",
          "authorAvatarURL": null,
          "canDelete": true
        }
      ],
      "nextCursor": "66666666-7777-4888-9999-000000000000"
    }
    """

    private static let createdPayload = """
    {
      "comment": {
        "id": "66666666-7777-4888-9999-000000000000",
        "body": "Hello",
        "language": null,
        "createdAt": "2026-10-30T12:00:00.000Z",
        "authorName": "@me",
        "authorAvatarURL": null,
        "canDelete": true
      }
    }
    """

    private static func date(hour: Int, minute: Int, second: Int, millisecond: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 30, hour: hour, minute: minute, second: second,
            nanosecond: millisecond * 1_000_000
        ))!
    }

    // MARK: - fetchComments

    @Test func fetchDecodesCommentsAndCursor() async throws {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(Self.listPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        let page = try await client.fetchComments(videoID: Self.videoID)

        #expect(page.items.count == 2)
        #expect(page.nextCursor == Self.commentID)

        let first = try #require(page.items.first)
        #expect(first.id == UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        #expect(first.body == "Nice view")
        #expect(first.language == "th")
        #expect(first.authorName == "@friend")
        #expect(first.authorAvatarURL == URL(string: "https://example.com/a.jpg"))
        #expect(first.canDelete == false)
        #expect(abs(first.createdAt.timeIntervalSince(Self.date(hour: 12, minute: 34, second: 56, millisecond: 789))) < 0.001)

        let second = try #require(page.items.last)
        #expect(second.language == nil)
        #expect(second.authorAvatarURL == nil)
        #expect(second.canDelete == true)
    }

    @Test func fetchDecodesTheLastPageWithoutACursor() async throws {
        let payload = #"{"items":[],"nextCursor":null}"#
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(payload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        let page = try await client.fetchComments(videoID: Self.videoID)

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test func fetchSendsLimitCursorAndBearerToken() async throws {
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(Self.listPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        _ = try await client.fetchComments(videoID: Self.videoID, cursor: Self.commentID, limit: 20)

        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/videos/\(Self.videoID.uuidString)/comments") == true)
        let query = URLComponents(url: try #require(capturedRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "limit" }?.value == "20")
        #expect(query?.first { $0.name == "cursor" }?.value == Self.commentID.uuidString)
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func fetchWithoutASessionSendsNoAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(Self.listPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        _ = try await client.fetchComments(videoID: Self.videoID)

        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchRetriesAsAGuestWhenTheSessionIsRejected() async throws {
        var requests: [URLRequest] = []
        let session = StubURLSessionFactory.make { request in
            requests.append(request)
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return (StubURLSessionFactory.httpResponse(for: request, statusCode: 401), Data())
            }
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(Self.listPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        let page = try await client.fetchComments(videoID: Self.videoID)

        #expect(page.items.count == 2)
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchGivesUpWhenEvenTheGuestReadIsRejected() async {
        var requests: [URLRequest] = []
        let session = StubURLSessionFactory.make { request in
            requests.append(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 401), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: CommentError.serverError(401)) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
        #expect(requests.count == 2)
    }

    @Test func aGuestReadThatIsRejectedIsNotRetried() async {
        var requestCount = 0
        let session = StubURLSessionFactory.make { request in
            requestCount += 1
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 401), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.serverError(401)) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
        #expect(requestCount == 1)
    }

    @Test func fetchMapsNotFound() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 404), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.notFound) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
    }

    @Test func fetchTreatsTooManyRequestsAsAServerError() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 429), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.serverError(429)) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
    }

    @Test func fetchMapsServerError() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 500), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.serverError(500)) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
    }

    @Test func fetchRejectsAMalformedBody() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(#"{"items":"nope"}"#.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.invalidResponse) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
    }

    @Test func fetchRejectsAnUnreadableDate() async {
        let payload = """
        {"items":[{"id":"11111111-2222-4333-8444-555555555555","body":"x","language":null,
        "createdAt":"yesterday","authorName":"@a","authorAvatarURL":null,"canDelete":false}],"nextCursor":null}
        """
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(payload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.invalidResponse) {
            _ = try await client.fetchComments(videoID: Self.videoID)
        }
    }

    @Test func fetchAcceptsADateWithoutFractionalSeconds() async throws {
        let payload = """
        {"items":[{"id":"11111111-2222-4333-8444-555555555555","body":"x","language":null,
        "createdAt":"2026-10-30T12:34:56Z","authorName":"@a","authorAvatarURL":null,"canDelete":false}],"nextCursor":null}
        """
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(payload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        let page = try await client.fetchComments(videoID: Self.videoID)

        #expect(page.items.first?.createdAt == Self.date(hour: 12, minute: 34, second: 56))
    }

    // MARK: - postComment

    @Test func postSendsTheBodyAsJSONWithBearerToken() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            capturedBody = request.readBody()
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data(Self.createdPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        let comment = try await client.postComment(videoID: Self.videoID, body: "Hello")

        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/videos/\(Self.videoID.uuidString)/comments") == true)
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sent = try JSONSerialization.jsonObject(with: try #require(capturedBody)) as? [String: Any]
        #expect(sent?["body"] as? String == "Hello")
        #expect(sent?["language"] == nil)

        #expect(comment.id == Self.commentID)
        #expect(comment.body == "Hello")
        #expect(comment.canDelete == true)
    }

    @Test func postIncludesTheLanguageWhenGiven() async throws {
        var capturedBody: Data?
        let session = StubURLSessionFactory.make { request in
            capturedBody = request.readBody()
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data(Self.createdPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        _ = try await client.postComment(videoID: Self.videoID, body: "สวัสดี", language: "th")

        let sent = try JSONSerialization.jsonObject(with: try #require(capturedBody)) as? [String: Any]
        #expect(sent?["body"] as? String == "สวัสดี")
        #expect(sent?["language"] as? String == "th")
    }

    @Test func postWithoutASessionNeverReachesTheNetwork() async {
        var requestCount = 0
        let session = StubURLSessionFactory.make { request in
            requestCount += 1
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data(Self.createdPayload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.signInRequired) {
            _ = try await client.postComment(videoID: Self.videoID, body: "Hello")
        }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, CommentError.signInRequired),
        (404, CommentError.notFound),
        (400, CommentError.invalidBody),
        (422, CommentError.invalidBody),
        (429, CommentError.rateLimited),
        (503, CommentError.serverError(503)),
    ])
    func postMapsStatusCodes(statusCode: Int, expected: CommentError) async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: statusCode), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) {
            _ = try await client.postComment(videoID: Self.videoID, body: "Hello")
        }
    }

    @Test func postRejectsAMalformedBody() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 201), Data(#"{"comment":{}}"#.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: CommentError.invalidResponse) {
            _ = try await client.postComment(videoID: Self.videoID, body: "Hello")
        }
    }

    // MARK: - deleteComment

    @Test func deleteSendsDeleteWithBearerToken() async throws {
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data(#"{"status":"deleted"}"#.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        try await client.deleteComment(videoID: Self.videoID, commentID: Self.commentID)

        #expect(capturedRequest?.httpMethod == "DELETE")
        #expect(
            capturedRequest?.url?.path().hasSuffix(
                "/v1/videos/\(Self.videoID.uuidString)/comments/\(Self.commentID.uuidString)"
            ) == true
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func deleteWithoutASessionNeverReachesTheNetwork() async {
        var requestCount = 0
        let session = StubURLSessionFactory.make { request in
            requestCount += 1
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: nil)
        await #expect(throws: CommentError.signInRequired) {
            try await client.deleteComment(videoID: Self.videoID, commentID: Self.commentID)
        }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, CommentError.signInRequired),
        (404, CommentError.notFound),
        (400, CommentError.serverError(400)),
        (500, CommentError.serverError(500)),
    ])
    func deleteMapsStatusCodes(statusCode: Int, expected: CommentError) async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: statusCode), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = CommentsAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) {
            try await client.deleteComment(videoID: Self.videoID, commentID: Self.commentID)
        }
    }

    // MARK: - URLs

    @Test func commentsURLClampsTheLimitToWhatTheWorkerAccepts() throws {
        func limit(_ requested: Int) throws -> String? {
            let url = try APIConfiguration.commentsURL(videoID: Self.videoID, limit: requested)
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value
        }
        #expect(try limit(500) == "50")
        #expect(try limit(0) == "1")
        #expect(try limit(30) == "30")
    }

    @Test func commentsURLHasNoQueryWhenNothingIsAsked() throws {
        let url = try APIConfiguration.commentsURL(videoID: Self.videoID)
        #expect(url.query == nil)
    }
}

private struct CommentsTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}

private extension URLRequest {
    /// A URLSession hands a stub protocol the body as a stream rather than as `httpBody`.
    func readBody() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
