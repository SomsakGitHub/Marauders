//
//  UserLocationAPIClient.swift
//  Marauders
//

import Foundation

enum UserLocationAPIError: LocalizedError, Equatable {
    case notAuthenticated
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in required"
        case .serverError(let code):
            return "Location report failed (status \(code))"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

struct UserLocationAPIClient: Sendable {
    private let session: URLSession
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.session = session
        self.authorization = authorization
    }

    func report(location: ClipLocation) async throws {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserLocationAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.userLocationURL()
        AppLog.info("api.location", "POST \(requestURL.host ?? "?")/v1/users/me/location")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(
            Body(latitude: location.latitude, longitude: location.longitude)
        )

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserLocationAPIError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw UserLocationAPIError.serverError(http.statusCode)
        }
    }

    private struct Body: Encodable {
        let latitude: Double
        let longitude: Double
    }
}
