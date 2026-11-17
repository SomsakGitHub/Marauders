//
//  AuthAPIClientProtocol.swift
//  Marauders
//

import Foundation

public enum AuthAPIError: LocalizedError, Equatable {
    case invalidIdentityToken
    case invalidResponse
    /// The Worker refused the refresh token (400 or 401 from `/v1/auth/refresh`): it was spent, revoked or has expired.
    case refreshRejected
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentityToken:
            return "Sign in could not be verified"
        case .invalidResponse:
            return "Invalid sign-in response"
        case .refreshRejected:
            return "Your session has ended. Please sign in again."
        case .serverError(let statusCode):
            switch statusCode {
            case 500...599:
                return "The service is temporarily unavailable. Please try again."
            default:
                return "Sign in failed. Please try again."
            }
        }
    }

    public var httpStatusCode: Int? {
        switch self {
        case .serverError(let statusCode):
            return statusCode
        case .invalidIdentityToken, .invalidResponse, .refreshRejected:
            return nil
        }
    }
}

public protocol AuthAPIClientProtocol: Sendable {
    /// Opens a session. The answer carries a refresh token when the Worker supports them (it is asked to at every
    /// sign-in), and none when it does not.
    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens
    /// Trades a refresh token for a new pair; the old refresh token is spent. The answer always carries a refresh
    /// token: one without a valid one throws `.invalidResponse`. The Worker refusing the token is `.refreshRejected`.
    func refreshTokens(using refreshToken: String) async throws -> AuthTokens
    /// Ends the session on the Worker by revoking the refresh token's whole family. It sends no access token.
    func revokeRefreshToken(_ refreshToken: String) async throws
}

/// Signs in a named test user, for the Simulator where Sign in with Apple has no account. Only a Debug build has an
/// implementation (`DevAuthAPIClient`), but the protocol exists in every configuration because `AuthViewModel`'s
/// initializer names it, and a Release build has to compile that initializer too.
public protocol DevAuthExchanging: Sendable {
    func tokens(secret: String, label: String, countryCode: String) async throws -> AuthTokens
}
