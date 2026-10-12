//
//  UserLocationAPIClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@Suite(.serialized)
@MainActor
struct UserLocationAPIClientTests {
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!
    private static let authorization = UserLocationTestAuthorization()

    @Test func reportPostsLocationWithBearerToken() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, Data("{\"latitude\":13.7563}".utf8))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserLocationAPIClient(session: session, authorization: Self.authorization)
        try await client.report(location: Self.bangkok)

        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/users/me/location") == true)
        #expect(
            capturedRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        )

        let body = try #require(capturedBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["latitude"] as? Double == 13.7563)
        #expect(json["longitude"] as? Double == 100.5018)
    }

    @Test func reportThrowsWhenNotAuthenticated() async {
        let session = StubURLSessionFactory.make { request in
            Issue.record("Network must not run without auth")
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserLocationAPIClient(session: session, authorization: nil)
        await #expect(throws: UserLocationAPIError.notAuthenticated) {
            try await client.report(location: Self.bangkok)
        }
    }

    @Test func reportThrowsServerErrorOnFailure() async {
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 500)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = UserLocationAPIClient(session: session, authorization: Self.authorization)
        await #expect(throws: UserLocationAPIError.serverError(500)) {
            try await client.report(location: Self.bangkok)
        }
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private struct UserLocationTestAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? {
        "Bearer \(String(repeating: "t", count: 40))"
    }
}
