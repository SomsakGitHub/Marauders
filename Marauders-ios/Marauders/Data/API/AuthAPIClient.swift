//
//  AuthAPIClient.swift
//  Marauders
//

import Foundation

struct AuthAPIResponse: Decodable, Sendable {
    let accessToken: String
}

enum AuthAPIError: LocalizedError, Equatable {
    case invalidIdentityToken
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentityToken:
            return "Sign in could not be verified"
        case .invalidResponse:
            return "Invalid sign-in response"
        case .serverError(let code):
            return "Sign in failed (status \(code))"
        }
    }
}

protocol AuthAPIClientProtocol: Sendable {
    func exchangeAppleIdentityToken(_ identityToken: String) async throws -> String
}

struct AuthAPIClient: AuthAPIClientProtocol, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func exchangeAppleIdentityToken(_ identityToken: String) async throws -> String {
        let trimmed = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 8192 else {
            throw AuthAPIError.invalidIdentityToken
        }

        let requestURL = try APIConfiguration.appleAuthURL()
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(["identityToken": trimmed])

        AppLog.info("api.auth", "POST /v1/auth/apple")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthAPIError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw AuthAPIError.invalidIdentityToken
            }
            throw AuthAPIError.serverError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(AuthAPIResponse.self, from: data)
        guard APIAccessTokenFormat.isValid(decoded.accessToken) else {
            throw AuthAPIError.invalidResponse
        }
        return decoded.accessToken
    }
}
