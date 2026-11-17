//
//  DevAuthAPIClient.swift
//  Marauders
//

#if DEBUG
    import Foundation
    import MaraudersAuth

    /// Signs in a named test user through `/v1/auth/dev` (`DevLogin` in `Shared/Configuration` holds its settings).
    /// Compiled into debug builds only.
    public struct DevAuthAPIClient: DevAuthExchanging {
        private let transport: any AuthTransport
        private let baseURL: @MainActor () throws -> URL

        /// - Parameters:
        ///   - transport: Sends the request; the app supplies its own HTTP client.
        ///   - baseURL: The Worker's origin, asked for once per request.
        public init(transport: any AuthTransport, baseURL: @escaping @MainActor () throws -> URL) {
            self.transport = transport
            self.baseURL = baseURL
        }

        public func tokens(secret: String, label: String, countryCode: String) async throws -> AuthTokens {
            var request = URLRequest(url: try AuthRoute.dev.url(relativeTo: try baseURL()))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            request.httpBody = try JSONEncoder().encode(
                Body(secret: secret, label: label, country: countryCode.uppercased(), supportsRefreshTokens: true))

            AuthLog.info("api.auth", "POST /v1/auth/dev")

            let response = try await transport.data(request)
            guard response.isSuccess else {
                throw AuthAPIError.serverError(response.statusCode)
            }

            return try JSONDecoder().decode(AuthAPIResponse.self, from: response.data).tokens()
        }

        private struct Body: Encodable {
            let secret: String
            let label: String
            let country: String
            let supportsRefreshTokens: Bool
        }
    }
#endif
