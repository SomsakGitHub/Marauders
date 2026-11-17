import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth
@testable import MaraudersAuthData

/// The app's side of the session package (`AuthModuleBridge`): what the app's HTTP client throws reaches the package's
/// code as the client threw it.
@MainActor
struct AuthModuleBridgeTests {
    /// The shape of a real refresh token: 43 base64url characters.
    private static let refreshToken = String(repeating: "Ab-_0", count: 8) + "xyz"

    /// The token refresher asks once more only after a `URLError` or an error marked `AuthTransportFailure`. If the
    /// bridge wrapped the client's error in another type on the way, that second try would be lost and no test of the
    /// refresher would notice: they hand it the error above the client.
    @Test(arguments: [
        HTTPClientError.transport("offline") as any Error,
        HTTPClientError.invalidResponse,
        URLError(.notConnectedToInternet),
    ])
    func anErrorOfTheAppsClientComesThroughTheBridgeAsItIs(failure: any Error) async {
        let http = RecordingTransport([.failure(failure)])
        let client = AuthAPIClient(
            transport: HTTPClientAuthTransport(http), baseURL: { try APIConfiguration.apiBaseURL() })

        do {
            _ = try await client.refreshTokens(using: Self.refreshToken)
            Issue.record("the refresh should have thrown")
        } catch {
            #expect(error is URLError || error is any AuthTransportFailure, "the refresher asks again after this")
            if let expected = failure as? HTTPClientError {
                #expect(error as? HTTPClientError == expected)
            } else {
                #expect((error as? URLError)?.code == (failure as? URLError)?.code)
            }
        }
        #expect(http.requests.count == 1)
    }
}
