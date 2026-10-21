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
        case .serverError(let statusCode):
            switch statusCode {
            case 500 ... 599:
                return "The service is temporarily unavailable. Please try again."
            default:
                return "Sign in failed. Please try again."
            }
        }
    }

    var httpStatusCode: Int? {
        switch self {
        case .serverError(let statusCode):
            return statusCode
        case .invalidIdentityToken, .invalidResponse:
            return nil
        }
    }
}

protocol AuthAPIClientProtocol: Sendable {
    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> String
}

struct AuthAPIClient: AuthAPIClientProtocol, Sendable {
    private let client: HTTPClient

    init(session: URLSession = .shared) {
        self.init(client: AlamofireHTTPClient(session: session))
    }

    init(client: HTTPClient) {
        self.client = client
    }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> String {
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
        request.httpBody = try JSONEncoder().encode([
            "identityToken": trimmed,
            "country": countryCode.uppercased()
        ])

        AppLog.info("api.auth", "POST /v1/auth/apple")

        let response = try await client.data(request)

        guard response.isSuccess else {
            if response.statusCode == 401 {
                throw AuthAPIError.invalidIdentityToken
            }
            throw AuthAPIError.serverError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(AuthAPIResponse.self, from: response.data)
        guard APIAccessTokenFormat.isValid(decoded.accessToken) else {
            throw AuthAPIError.invalidResponse
        }
        return decoded.accessToken
    }
}
