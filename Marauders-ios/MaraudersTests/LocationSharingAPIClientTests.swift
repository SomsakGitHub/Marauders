//
//  LocationSharingAPIClientTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@Suite(.serialized)
@MainActor
struct LocationSharingAPIClientTests {
    private static let authorization = SharingTestAuthorization()

    private static func session(
        status: Int = 200,
        body: String,
        capture: ((URLRequest) -> Void)? = nil
    ) -> URLSession {
        StubURLSessionFactory.make { request in
            capture?(request)
            return (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
        }
    }

    @Test func friendLocationsAreReadWithTheSessionAndDecoded() async throws {
        let body = """
        {"sharing":true,"items":[
          {"handle":"@alice","avatarURL":"https://media.test/a.jpg","latitude":13.75,"longitude":100.5,"locationUpdatedAt":"2026-11-01T10:00:00.123Z"},
          {"handle":"@bob","avatarURL":null,"latitude":-33.86,"longitude":151.2,"locationUpdatedAt":null}
        ]}
        """
        var captured: URLRequest?
        let session = Self.session(body: body) { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let result = try await LocationSharingAPIClient(session: session, authorization: Self.authorization).friendLocations()

        #expect(captured?.httpMethod == "GET")
        #expect(captured?.url?.path().hasSuffix("/v1/users/me/friend-locations") == true)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(result.sharing)
        #expect(result.friends.map(\.handle) == ["@alice", "@bob"])
        #expect(result.friends[0].avatarURL == URL(string: "https://media.test/a.jpg"))
        let updatedAt = try #require(result.friends[0].updatedAt)
        #expect(abs(updatedAt.timeIntervalSince1970 - 1_793_527_200.123) < 0.000_5, "milliseconds included")
        #expect(result.friends[1].updatedAt == nil)
        #expect(result.friends[1].latitude == -33.86)
    }

    /// The map could not place such a point; the rest of the list still shows.
    @Test func aPointOffTheEarthIsLeftOut() async throws {
        let body = """
        {"sharing":true,"items":[
          {"handle":"@alice","latitude":91,"longitude":100.5,"locationUpdatedAt":null},
          {"handle":"@bob","latitude":13.7,"longitude":181,"locationUpdatedAt":null},
          {"handle":"@carol","latitude":13.7,"longitude":100.5,"locationUpdatedAt":null}
        ]}
        """
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        let result = try await LocationSharingAPIClient(session: session, authorization: Self.authorization).friendLocations()

        #expect(result.friends.map(\.handle) == ["@carol"])
    }

    @Test func turningSharingOnSendsAPutWithTheChoice() async throws {
        var captured: URLRequest?
        let session = Self.session(body: #"{"sharesLocation":true}"#) { captured = $0 }
        defer { StubURLSessionFactory.reset(session) }

        let stored = try await LocationSharingAPIClient(session: session, authorization: Self.authorization).setSharing(true)

        #expect(stored)
        #expect(captured?.httpMethod == "PUT")
        #expect(captured?.url?.path().hasSuffix("/v1/users/me/location-sharing") == true)
        #expect(captured?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONSerialization.jsonObject(with: captured?.readBody() ?? Data()) as? [String: Bool]
        #expect(sent == ["enabled": true])
    }

    @Test func aGuestNeverSendsARequest() async {
        var requestCount = 0
        let session = Self.session(body: "{}") { _ in requestCount += 1 }
        defer { StubURLSessionFactory.reset(session) }

        let client = LocationSharingAPIClient(session: session, authorization: nil)
        await #expect(throws: LocationSharingError.signInRequired) { try await client.friendLocations() }
        await #expect(throws: LocationSharingError.signInRequired) { try await client.setSharing(true) }
        #expect(requestCount == 0)
    }

    @Test(arguments: [
        (401, LocationSharingError.signInRequired),
        (429, LocationSharingError.rateLimited),
        (400, LocationSharingError.serverError(400)),
        (500, LocationSharingError.serverError(500)),
    ])
    func mapsStatusCodes(statusCode: Int, expected: LocationSharingError) async {
        let session = Self.session(status: statusCode, body: "")
        defer { StubURLSessionFactory.reset(session) }

        let client = LocationSharingAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: expected) { try await client.setSharing(false) }
        await #expect(throws: expected) { try await client.friendLocations() }
    }

    @Test(arguments: ["", "not json", #"{"items":[]}"#, #"{"sharing":true}"#])
    func anAnswerThatIsNotAListIsInvalid(body: String) async {
        let session = Self.session(body: body)
        defer { StubURLSessionFactory.reset(session) }

        await #expect(throws: LocationSharingError.invalidResponse) {
            try await LocationSharingAPIClient(session: session, authorization: Self.authorization).friendLocations()
        }
    }
}

private struct SharingTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { "Bearer test-token" }
}
