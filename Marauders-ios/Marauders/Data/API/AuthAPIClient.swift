//
//  AuthAPIClient.swift
//  Marauders
//

import Foundation

struct AuthAPIResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?

    /// The tokens of an answer. Each one present must have the shape the Worker issues: an answer carrying a token that
    /// does not is a broken answer, never a session that quietly goes without refreshing.
    func tokens() throws -> AuthTokens {
        guard APIAccessTokenFormat.isValid(accessToken) else {
            throw AuthAPIError.invalidResponse
        }
        if let refreshToken, !APIRefreshTokenFormat.isValid(refreshToken) {
            throw AuthAPIError.invalidResponse
        }
        return AuthTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
}

struct AuthAPIClient: AuthAPIClientProtocol, Sendable {
    private let client: HTTPClient

    init(session: URLSession = .shared) {
        self.init(client: URLSessionHTTPClient(session: session))
    }

    init(client: HTTPClient) {
        self.client = client
    }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        let trimmed = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 8192 else {
            throw AuthAPIError.invalidIdentityToken
        }

        let request = try Self.jsonPost(
            try APIConfiguration.appleAuthURL(),
            timeout: 30,
            body: AppleSignInBody(
                identityToken: trimmed, country: countryCode.uppercased(), supportsRefreshTokens: true)
        )

        AppLog.info("api.auth", "POST /v1/auth/apple")

        let response = try await client.data(request)

        guard response.isSuccess else {
            if response.statusCode == 401 {
                throw AuthAPIError.invalidIdentityToken
            }
            throw AuthAPIError.serverError(response.statusCode)
        }

        return try JSONDecoder().decode(AuthAPIResponse.self, from: response.data).tokens()
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        let request = try Self.jsonPost(
            try APIConfiguration.refreshAuthURL(), timeout: 30, body: RefreshTokenBody(refreshToken: refreshToken))

        AppLog.info("api.auth", "POST /v1/auth/refresh")

        let response = try await client.data(request)

        guard response.isSuccess else {
            switch response.statusCode {
            case 400, 401:
                throw AuthAPIError.refreshRejected
            default:
                throw AuthAPIError.serverError(response.statusCode)
            }
        }

        // Anything the Worker answers with 200 that is not a full pair is a broken answer (a proxy page, a Worker
        // from another version), not a verdict on the token: the caller keeps the session and tries again later.
        let tokens: AuthTokens
        do {
            tokens = try JSONDecoder().decode(AuthAPIResponse.self, from: response.data).tokens()
        } catch {
            throw AuthAPIError.invalidResponse
        }
        guard tokens.refreshToken != nil else {
            throw AuthAPIError.invalidResponse
        }
        return tokens
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        let request = try Self.jsonPost(
            try APIConfiguration.signOutAuthURL(), timeout: 10, body: RefreshTokenBody(refreshToken: refreshToken))

        AppLog.info("api.auth", "POST /v1/auth/signout")

        let response = try await client.data(request)

        guard response.isSuccess else {
            throw AuthAPIError.serverError(response.statusCode)
        }
    }

    private static func jsonPost(_ url: URL, timeout: TimeInterval, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private struct AppleSignInBody: Encodable {
        let identityToken: String
        let country: String
        /// Tells the Worker this app can keep and spend a refresh token, so the answer may carry one.
        let supportsRefreshTokens: Bool
    }

    private struct RefreshTokenBody: Encodable {
        let refreshToken: String
    }
}
