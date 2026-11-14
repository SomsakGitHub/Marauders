//
//  AuthAPIClientProtocol.swift
//  Marauders
//

import Foundation

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
            case 500...599:
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

/// Signs in a named test user, for the Simulator where Sign in with Apple has no account. Only a Debug build has an
/// implementation (`DevAuthAPIClient`), but the protocol exists in every configuration because `AuthViewModel`'s
/// initializer names it, and a Release build has to compile that initializer too.
protocol DevAuthExchanging: Sendable {
    func accessToken(secret: String, label: String, countryCode: String) async throws -> String
}
