//
//  FeedAPIClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@Suite(.serialized)
@MainActor
struct FeedAPIClientTests {
    @Test func fetchFeedSuccessDecodesHTTPSItems() async throws {
        let videoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let body = FeedAPIClientTests.feedResponseJSON(
            items: [(id: videoID, streamURL: "https://cdn.example.com/v/1.mp4")]
        )

        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(session: session)
        let page = try await client.fetchFeed(limit: 20)

        #expect(page.items.count == 1)
        #expect(page.items[0].id == videoID)
        #expect(page.items[0].streamURL.absoluteString == "https://cdn.example.com/v/1.mp4")
        #expect(page.hasMore == false)

        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/feed") == true)
        let limit = URLComponents(url: capturedRequest!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "limit" })?
            .value
        #expect(limit == "20")
    }

    @Test func fetchFeedPassesCursorQueryParam() async throws {
        let cursor = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let body = FeedAPIClientTests.feedResponseJSON(items: [])

        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(session: session)
        _ = try await client.fetchFeed(limit: 10, cursor: cursor)

        let cursorValue = URLComponents(url: capturedRequest!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cursor" })?
            .value
        #expect(cursorValue?.lowercased() == cursor.uuidString.lowercased())
    }

    @Test func fetchFeedRejectsInvalidLimitBeforeNetwork() async {
        let client = FeedAPIClient(session: URLSession(configuration: .ephemeral))

        await #expect(throws: FeedAPIError.invalidLimit) {
            try await client.fetchFeed(limit: 0)
        }
    }

    @Test func fetchFeedMapsServerErrorStatusAfterRetriesExhausted() async {
        nonisolated(unsafe) var attemptCount = 0
        let session = StubURLSessionFactory.make { request in
            attemptCount += 1
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 503)
            return (response, Data("{}".utf8))
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(
            session: session,
            maxAttempts: FeedAPIClient.defaultMaxAttempts,
            retryDelayNs: { _ in 0 }
        )

        await #expect(throws: FeedAPIError.serverError(503)) {
            try await client.fetchFeed()
        }
        #expect(attemptCount == FeedAPIClient.defaultMaxAttempts)
    }

    @Test func fetchFeedRetriesTransient503ThenSucceeds() async throws {
        let videoID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let successBody = FeedAPIClientTests.feedResponseJSON(
            items: [(id: videoID, streamURL: "https://cdn.example.com/v/ok.mp4")]
        )

        nonisolated(unsafe) var attemptCount = 0
        let session = StubURLSessionFactory.make { request in
            attemptCount += 1
            if attemptCount < 2 {
                let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 503)
                return (response, Data())
            }
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, successBody)
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(
            session: session,
            maxAttempts: FeedAPIClient.defaultMaxAttempts,
            retryDelayNs: { _ in 0 }
        )
        let page = try await client.fetchFeed()

        #expect(attemptCount == 2)
        #expect(page.items.count == 1)
        #expect(page.items[0].id == videoID)
    }

    @Test func fetchFeedDoesNotRetryClientError() async {
        nonisolated(unsafe) var attemptCount = 0
        let session = StubURLSessionFactory.make { request in
            attemptCount += 1
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 400)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(
            session: session,
            maxAttempts: FeedAPIClient.defaultMaxAttempts,
            retryDelayNs: { _ in 0 }
        )

        await #expect(throws: FeedAPIError.serverError(400)) {
            try await client.fetchFeed()
        }
        #expect(attemptCount == 1)
    }

    @Test func fetchFeedRejectsMalformedJSON() async {
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, Data("{not-json".utf8))
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(session: session)

        await #expect(throws: FeedAPIError.invalidResponse) {
            try await client.fetchFeed()
        }
    }

    @Test func fetchFeedRejectsNonHTTPSStreamURLInPayload() async {
        let body = FeedAPIClientTests.feedResponseJSON(
            items: [(id: UUID(), streamURL: "http://insecure.example.com/v.mp4")]
        )
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset() }

        let client = FeedAPIClient(session: session)

        await #expect(throws: FeedAPIError.invalidResponse) {
            try await client.fetchFeed()
        }
    }
}

private extension FeedAPIClientTests {
    static func feedResponseJSON(items: [(id: UUID, streamURL: String)]) -> Data {
        let payload: [String: Any] = [
            "items": items.map { item in
                ["id": item.id.uuidString, "streamURL": item.streamURL]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
