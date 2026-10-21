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
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: AlamofireHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
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

        let response = try await client.data(request)
        guard response.isSuccess else {
            throw UserLocationAPIError.serverError(response.statusCode)
        }
    }

    private struct Body: Encodable {
        let latitude: Double
        let longitude: Double
    }
}
