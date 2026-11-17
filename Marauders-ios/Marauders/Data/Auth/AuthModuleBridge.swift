//
//  AuthModuleBridge.swift
//  Marauders
//

import Foundation
import MaraudersAuth
import MaraudersAuthData

// The app's side of the session module (`Packages/MaraudersAuth`). The module owns what a session is, where it is kept
// and how the Worker is asked for one, and it knows nothing of the app. What it needs from the app comes through this
// file: a way to send a request, the Worker's origin, and the app's log.

/// Sends the session module's requests through one of the app's HTTP clients.
struct HTTPClientAuthTransport: AuthTransport {
    private let client: any HTTPClient

    init(_ client: any HTTPClient) {
        self.client = client
    }

    func data(_ request: URLRequest) async throws -> AuthTransportResponse {
        let response = try await client.data(request)
        return AuthTransportResponse(data: response.data, statusCode: response.statusCode)
    }
}

/// A request the app's client could not send or get answered. The token refresher asks once more after one.
extension HTTPClientError: AuthTransportFailure {}

extension AuthAPIClient {
    /// The client of the Worker's auth routes as the app uses it: over a plain `URLSession` client, never the stack
    /// that refreshes a rejected token, and under the origin `APIConfiguration` gives.
    init(session: URLSession = .shared) {
        self.init(
            transport: HTTPClientAuthTransport(URLSessionHTTPClient(session: session)),
            baseURL: { try APIConfiguration.apiBaseURL() })
    }
}

#if DEBUG
    extension DevAuthAPIClient {
        init(client: any HTTPClient = URLSessionHTTPClient()) {
            self.init(transport: HTTPClientAuthTransport(client), baseURL: { try APIConfiguration.apiBaseURL() })
        }
    }
#endif

extension AuthLog {
    /// Points the session module's log at the app's. `MaraudersApp` calls it first thing at launch.
    static func forwardToAppLog() {
        sink = { level, category, message in
            switch level {
            case .info: AppLog.info(category, message)
            case .warning: AppLog.warning(category, message)
            case .error: AppLog.error(category, message)
            }
        }
    }
}
