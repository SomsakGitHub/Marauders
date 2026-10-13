//
//  UserProfileAPIClient.swift
//  Marauders
//

import Foundation

enum UserProfileAPIError: LocalizedError, Equatable {
    case notAuthenticated
    case notFound
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in required"
        case .notFound:
            return "Profile not found"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}

struct UserProfileAPIClient: Sendable {
    private let session: URLSession
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.session = session
        self.authorization = authorization
    }

    func fetchProfile() async throws -> UserProfile {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserProfileAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.userProfileURL()
        AppLog.info("api.profile", "GET \(requestURL.host ?? "?")/v1/users/me")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserProfileAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw UserProfileAPIError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data).profile
        } catch {
            AppLog.error("api.profile", "decode failed: \(error.localizedDescription)")
            throw UserProfileAPIError.invalidResponse
        }
    }

    func deleteClip(id: UUID) async throws {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserProfileAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.deleteVideoURL(id: id)
        AppLog.info("api.profile", "DELETE \(requestURL.host ?? "?")/v1/videos/\(id.uuidString)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserProfileAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw UserProfileAPIError.serverError(http.statusCode)
        }
    }

    private struct Response: Decodable {        let country: String?
        let latitude: Double?
        let longitude: Double?
        let videoCount: Int
        let videos: [FeedVideo]

        var profile: UserProfile {
            UserProfile(
                country: country,
                latitude: latitude,
                longitude: longitude,
                videoCount: videoCount,
                videos: videos
            )
        }
    }
}
