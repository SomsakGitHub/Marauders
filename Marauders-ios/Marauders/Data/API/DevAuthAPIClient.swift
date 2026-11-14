//
//  DevAuthAPIClient.swift
//  Marauders
//

#if DEBUG
    import Foundation

    /// Signs in a named test user through `/v1/auth/dev` (`DevLogin` in `Shared/Configuration` holds its settings).
    /// Compiled into debug builds only.
    struct DevAuthAPIClient: DevAuthExchanging {
        private let client: HTTPClient

        init(client: HTTPClient = URLSessionHTTPClient()) {
            self.client = client
        }

        func accessToken(secret: String, label: String, countryCode: String) async throws -> String {
            var request = URLRequest(url: try APIConfiguration.devAuthURL())
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            request.httpBody = try JSONEncoder().encode([
                "secret": secret,
                "label": label,
                "country": countryCode.uppercased(),
            ])

            AppLog.info("api.auth", "POST /v1/auth/dev")

            let response = try await client.data(request)
            guard response.isSuccess else {
                throw AuthAPIError.serverError(response.statusCode)
            }

            let decoded = try JSONDecoder().decode(AuthAPIResponse.self, from: response.data)
            guard APIAccessTokenFormat.isValid(decoded.accessToken) else {
                throw AuthAPIError.invalidResponse
            }
            return decoded.accessToken
        }
    }
#endif
