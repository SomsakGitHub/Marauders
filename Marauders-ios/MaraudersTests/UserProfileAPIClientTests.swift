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

    @Test func deleteClipSendsDeleteWithBearerToken() async throws {
        let id = UUID()
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 204), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        try await client.deleteClip(id: id)

        #expect(capturedRequest?.httpMethod == "DELETE")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/videos/\(id.uuidString)") == true)
        #expect(
            capturedRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        )
    }

    @Test func deleteClipThrowsWhenUnauthenticated() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 204), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: nil)
        await #expect(throws: UserProfileAPIError.notAuthenticated) {
            try await client.deleteClip(id: UUID())
        }
    }

    @Test func deleteClipMapsNotFound() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 404), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserProfileAPIError.notFound) {
            try await client.deleteClip(id: UUID())
        }
    }

    @Test func fetchPublicProfileDecodesWithoutAuth() async throws {
        let payload = """
        {
          "handle": "@friend",
          "country": "TH",
          "videoCount": 1,
          "videos": [
            {
              "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
              "streamURL": "https://example.com/clip.mp4",
              "latitude": null,
              "longitude": null,
              "country": "TH",
              "authorName": "@friend",
              "caption": "Hi",
              "musicTitle": null
            }
          ]
        }
        """
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200),
                    Data(payload.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: nil)
        let profile = try await client.fetchPublicProfile(handle: "@friend")

        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(profile.handle == "@friend")
        #expect(profile.videoCount == 1)
        #expect(profile.videos.first?.caption == "Hi")
    }

    @Test func fetchPublicProfileMapsNotFound() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 404), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: nil)
        await #expect(throws: UserProfileAPIError.notFound) {
            _ = try await client.fetchPublicProfile(handle: "@nobody")
        }
    }

    @Test func updateHandleSendsPatchWithBearerToken() async throws {
        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: 200),
                    Data(#"{"handle":"@new"}"#.utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        let saved = try await client.updateHandle("@NEW")

        #expect(saved == "@new")
        #expect(capturedRequest?.httpMethod == "PATCH")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/users/me") == true)
        #expect(
            capturedRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func updateHandleMapsHandleTaken() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 409), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserProfileAPIError.handleTaken) {
            _ = try await client.updateHandle("@taken")
        }
    }

    @Test func updateHandleMapsInvalidHandle() async {
        let session = StubURLSessionFactory.make { request in
            (StubURLSessionFactory.httpResponse(for: request, statusCode: 400), Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserProfileAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserProfileAPIError.invalidHandle) {
            _ = try await client.updateHandle("bad handle")
        }
    }
}

private struct UserProfileTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
