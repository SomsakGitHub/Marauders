import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth
@testable import MaraudersAuthData

/// The session package's transport seam can be filled by code that is on no actor: a transport builds its answer where
/// it runs, which need not be the main actor.
struct AuthTransportTests {
    /// A transport that is on no actor, as a test double of the seam is.
    private nonisolated final class OffMainTransport: AuthTransport, @unchecked Sendable {
        private let status: Int

        init(status: Int) {
            self.status = status
        }

        func data(_ request: URLRequest) async throws -> AuthTransportResponse {
            AuthTransportResponse(data: Data(), statusCode: status)
        }
    }

    @Test func anAnswerCanBeBuiltAndReadOffTheMainActor() {
        let answer = AuthTransportResponse(data: Data("ok".utf8), statusCode: 204)
        #expect(answer.isSuccess)
        #expect(answer.statusCode == 204)
        #expect(answer.data == Data("ok".utf8))
        #expect(!AuthTransportResponse(data: Data(), statusCode: 503).isSuccess)
    }

    @Test @MainActor func aTransportOnNoActorAnswersTheClient() async {
        let client = AuthAPIClient(
            transport: OffMainTransport(status: 503), baseURL: { try APIConfiguration.apiBaseURL() })
        await #expect(throws: AuthAPIError.serverError(503)) {
            try await client.revokeRefreshToken(String(repeating: "Ab-_0", count: 8) + "xyz")
        }
    }
}
