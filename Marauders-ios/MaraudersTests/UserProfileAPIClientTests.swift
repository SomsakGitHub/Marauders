//
//  UserProfileAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct UserProfileAPIClientTests {
    private static let authorization = UserProfileTestAuthorization()

    private static let payload = """
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "country": "TH",
      "latitude": 13.7563,
      "longitude": 100.5018,
      "locationUpdatedAt": null,
      "videoCount": 1,
      "videos": [
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "streamURL": "https://example.com/clip.mp4",
          "latitude": 13.7563,
          "longitude": 100.5018,
          "country": "TH",
          "authorName": "@marauders",
          "caption": "Sunset",
          "musicTitle": "Golden Hour"
        }
      ]
    }
    """

    @Test func fetchProfileDecodesProfileAndClips() async throws {
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200),
                    Data(Self.payload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        let profile = try await client.fetchProfile()

        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/users/me") == true)
        #expect(
            capturedRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        )
        #expect(profile.country == "TH")
        #expect(profile.videoCount == 1)
        #expect(profile.videos.count == 1)
        #expect(profile.videos.first?.caption == "Sunset")
    }

    @Test func fetchProfileThrowsWhenUnauthenticated() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 200), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: nil)
        await #expect(throws: UserProfileAPIError.notAuthenticated) {
            _ = try await client.fetchProfile()
        }
    }

    @Test func fetchProfileMapsNotFound() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 404), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserProfileAPIError.notFound) {
            _ = try await client.fetchProfile()
        }
    }

    @Test func fetchProfileMapsServerError() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 500), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserProfileAPIError.serverError(500)) {
            _ = try await client.fetchProfile()
        }
    }
}

private struct UserProfileTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
