//
//  IdempotentReplayResolverTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// How `IdempotentReplayResolver` asks the Worker for the clip it stored under an upload's key: an empty POST that
/// carries the key and the bearer, answered with the clip, or with a refusal that is never read as one.
@MainActor
struct IdempotentReplayResolverTests {
    /// Upper case on purpose: the header must go out in lower case.
    private static let key = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
    private static let token = UploaderKit.validToken()

    /// A resolver whose transport gives `result` once, and the transport, to read what it was asked.
    private static func resolver(
        answering result: Result<HTTPClientResponse, any Error>
    ) -> (resolver: IdempotentReplayResolver, transport: RecordingTransport) {
        let transport = RecordingTransport([result])
        return (IdempotentReplayResolver(client: transport), transport)
    }

    private static func answer(status: Int, body: Data) -> Result<HTTPClientResponse, any Error> {
        .success(HTTPClientResponse(data: body, statusCode: status))
    }

    @Test func theReplayIsABodylessPostWithTheKeyAndTheBearer() async throws {
        let clipID = UUID()
        let (resolver, transport) = Self.resolver(
            answering: Self.answer(status: 200, body: UploaderKit.answer(id: clipID)))

        let item = try await resolver.storedClip(forKey: Self.key, accessToken: Self.token)

        #expect(item == UploaderKit.item(id: clipID))
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(transport.uploadedParts.isEmpty)
        #expect(request.httpMethod == "POST")
        // Compared as text: `videoUploadURL()` is relative to the base URL, and a request hands back the absolute one.
        let uploadURL = try APIConfiguration.videoUploadURL()
        #expect(request.url?.absoluteString == uploadURL.absoluteString)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    /// The Worker's answer to a POST with no form is a 400; every status outside 2xx ends the same way, whatever the
    /// body says: a refusal that happens to hold a clip is still a refusal.
    private static let refusal = Data(#"{"error":"expected multipart form data"}"#.utf8)

    @Test(arguments: [400, 401, 404, 429, 500, 503, 300])
    func aNon2xxAnswerThrowsAServerError(_ status: Int) async {
        let (resolver, _) = Self.resolver(answering: Self.answer(status: status, body: Self.refusal))

        await #expect(throws: VideoUploadAPIError.serverError(status)) {
            try await resolver.storedClip(forKey: Self.key, accessToken: Self.token)
        }
    }

    @Test func aNon2xxAnswerIsNotDecodedEvenWhenItHoldsAClip() async {
        let (resolver, _) = Self.resolver(answering: Self.answer(status: 500, body: UploaderKit.answer()))

        await #expect(throws: VideoUploadAPIError.serverError(500)) {
            try await resolver.storedClip(forKey: Self.key, accessToken: Self.token)
        }
    }

    @Test(arguments: [
        "", "not json", #"{"ok":true}"#, #"{"item":{}}"#,
        #"{"item":{"id":"22222222-2222-2222-2222-222222222222","streamURL":"http://cdn.example.com/v/new.mp4"}}"#,
    ])
    func aBodyThatIsNotAClipThrowsInvalidResponse(_ body: String) async {
        let (resolver, _) = Self.resolver(answering: Self.answer(status: 200, body: Data(body.utf8)))

        await #expect(throws: VideoUploadAPIError.invalidResponse) {
            try await resolver.storedClip(forKey: Self.key, accessToken: Self.token)
        }
    }

    @Test func aTransportFailureReachesTheCaller() async {
        let (resolver, _) = Self.resolver(answering: .failure(URLError(.notConnectedToInternet)))

        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await resolver.storedClip(forKey: Self.key, accessToken: Self.token)
        }
    }
}
