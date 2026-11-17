//
//  GuestFallbackTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

/// A public read the viewer may do without a session. With a session it goes out first; when that session is rejected,
/// or cannot be refreshed, the same read goes out once more as a guest, so the viewer still sees the clips.
@MainActor
struct GuestFallbackTests {
    private func request(token: String? = "session-token") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/clips?limit=20")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    @Test func a401FallsBackToAGuestRead() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(200, body: "as a guest"))])
        let original = request()

        let response = try await transport.dataFallingBackToGuest(original, logCategory: "api.guest-test")

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.data, as: UTF8.self) == "as a guest")
        #expect(transport.requests.count == 2)
        #expect(transport.requests.first == original)
        var guest = original
        guest.setValue(nil, forHTTPHeaderField: "Authorization")
        #expect(transport.requests.last == guest, "the same read, without the session")
    }

    @Test func anUnavailableSessionFallsBackToAGuestRead() async throws {
        let transport = RecordingTransport([
            .failure(SessionRefreshUnavailableError()), .success(reply(200, body: "as a guest")),
        ])
        let original = request()

        let response = try await transport.dataFallingBackToGuest(original, logCategory: "api.guest-test")

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.data, as: UTF8.self) == "as a guest")
        #expect(transport.requests.count == 2)
        #expect(transport.requests.first?.bearerToken == "session-token")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aTransportErrorIsNotTurnedIntoAGuestRead() async {
        let transport = RecordingTransport([.failure(URLError(.timedOut)), .success(reply(200))])

        await #expect(throws: URLError.self) {
            try await transport.dataFallingBackToGuest(request(), logCategory: "api.guest-test")
        }

        #expect(transport.requests.count == 1)
    }

    @Test func aGuestRequestIsSentOnce() async throws {
        let transport = RecordingTransport([.success(reply(401, body: "who are you")), .success(reply(200))])
        let guest = request(token: nil)

        let response = try await transport.dataFallingBackToGuest(guest, logCategory: "api.guest-test")

        #expect(response.statusCode == 401)
        #expect(String(decoding: response.data, as: UTF8.self) == "who are you")
        #expect(transport.requests == [guest])
    }

    @Test(arguments: [200, 304, 404, 500])
    func anAnswerThatIsNot401IsReturnedAsIs(status: Int) async throws {
        let transport = RecordingTransport([.success(reply(status, body: "answer")), .success(reply(200))])

        let response = try await transport.dataFallingBackToGuest(request(), logCategory: "api.guest-test")

        #expect(response.statusCode == status)
        #expect(String(decoding: response.data, as: UTF8.self) == "answer")
        #expect(transport.requests.count == 1)
    }

    @Test func anyOtherErrorPropagatesUnchangedAfterOneRequest() async {
        let failures: [any Error] = [
            HTTPClientError.transport("offline"),
            HTTPClientError.invalidResponse,
            AuthAPIError.serverError(503),
            CancellationError(),
        ]
        for failure in failures {
            let transport = RecordingTransport([.failure(failure), .success(reply(200))])

            do {
                _ = try await transport.dataFallingBackToGuest(request(), logCategory: "api.guest-test")
                Issue.record("\(failure) was swallowed")
            } catch {
                #expect(String(reflecting: error) == String(reflecting: failure))
            }
            #expect(transport.requests.count == 1, "\(failure)")
        }
    }

    @Test func aGuestReadThatIsRejectedAgainIsReturnedAndNotRepeated() async throws {
        let transport = RecordingTransport([.success(reply(401)), .success(reply(401, body: "still no"))])

        let response = try await transport.dataFallingBackToGuest(request(), logCategory: "api.guest-test")

        #expect(response.statusCode == 401)
        #expect(String(decoding: response.data, as: UTF8.self) == "still no")
        #expect(transport.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func aGuestReadThatFailsPropagatesItsError(sessionIsUnavailable: Bool) async {
        let first: Result<HTTPClientResponse, any Error> =
            sessionIsUnavailable ? .failure(SessionRefreshUnavailableError()) : .success(reply(401))
        let transport = RecordingTransport([first, .failure(URLError(.notConnectedToInternet))])

        await #expect(throws: URLError.self) {
            try await transport.dataFallingBackToGuest(request(), logCategory: "api.guest-test")
        }

        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func theFallbackIsLoggedUnderTheCallersCategoryWithoutAToken() async throws {
        let rejectedCategory = "api.guest-test.\(UUID().uuidString)"
        let unavailableCategory = "api.guest-test.\(UUID().uuidString)"

        _ = try await RecordingTransport([.success(reply(401)), .success(reply(200))])
            .dataFallingBackToGuest(request(), logCategory: rejectedCategory)
        _ = try await RecordingTransport([.failure(SessionRefreshUnavailableError()), .success(reply(200))])
            .dataFallingBackToGuest(request(), logCategory: unavailableCategory)

        #expect(await logged(rejectedCategory, "session rejected, reading as guest"))
        #expect(await logged(unavailableCategory, "session unavailable, reading as guest"))
        #expect(!AppLogStore.shared.entries.contains { $0.message.contains("session-token") })
    }

    /// `AppLog` writes from a task of its own, so an entry shows up a moment after the call that logged it.
    private func logged(_ category: String, _ message: String) async -> Bool {
        for _ in 0..<300 {
            let found = AppLogStore.shared.entries.contains {
                $0.category == category && $0.level == .warning && $0.message == message
            }
            if found { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private nonisolated func reply(_ status: Int, body: String = "") -> HTTPClientResponse {
    HTTPClientResponse(data: Data(body.utf8), statusCode: status)
}
