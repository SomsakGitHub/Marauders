//
//  UserProfileAPIClient.swift
//  Marauders
//

import Foundation

enum UserProfileAPIError: LocalizedError, Equatable {
    case notAuthenticated
    case notFound
    case handleTaken
    case invalidHandle
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in required"
        case .notFound:
            return "Profile not found"
        case .handleTaken:
            return "That handle is already taken"
        case .invalidHandle:
            return "Handles may use letters, numbers, dots and underscores"
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

    /// Fetches another user's public profile. No authentication required.
    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        let requestURL = try APIConfiguration.publicUserProfileURL(handle: handle)
        AppLog.info("api.profile", "GET \(requestURL.host ?? "?")/v1/users/<handle>")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        if http?.statusCode == 400 {
            throw UserProfileAPIError.invalidHandle
        }
        guard let http, (200 ... 299).contains(http.statusCode) else {
            throw UserProfileAPIError.serverError(http?.statusCode ?? -1)
        }

        do {
            return try JSONDecoder().decode(PublicResponse.self, from: data).profile
        } catch {
            AppLog.error("api.profile", "decode failed: \(error.localizedDescription)")
            throw UserProfileAPIError.invalidResponse
        }
    }

    /// Updates the signed-in user's public handle and returns the normalized value.
    @discardableResult
    func updateHandle(_ handle: String) async throws -> String {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserProfileAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.userProfileURL()
        AppLog.info("api.profile", "PATCH \(requestURL.host ?? "?")/v1/users/me")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["handle": handle])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserProfileAPIError.invalidResponse
        }
        switch http.statusCode {
        case 409:
            throw UserProfileAPIError.handleTaken
        case 400:
            throw UserProfileAPIError.invalidHandle
        case 401:
            throw UserProfileAPIError.notAuthenticated
        case 200 ... 299:
            break
        default:
            throw UserProfileAPIError.serverError(http.statusCode)
        }

        struct UpdateResponse: Decodable { let handle: String }
        do {
            return try JSONDecoder().decode(UpdateResponse.self, from: data).handle
        } catch {
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

    private struct Response: Decodable {
        let handle: String?
        let country: String?
        let latitude: Double?
        let longitude: Double?
        let videoCount: Int
        let videos: [FeedVideo]

        var profile: UserProfile {
            UserProfile(
                handle: handle ?? "@marauders",
                country: country,
                latitude: latitude,
                longitude: longitude,
                videoCount: videoCount,
                videos: videos
            )
        }
    }

    private struct PublicResponse: Decodable {
        let handle: String
        let country: String?
        let videoCount: Int
        let videos: [FeedVideo]

        var profile: PublicUserProfile {
            PublicUserProfile(
                handle: handle,
                country: country,
                videoCount: videoCount,
                videos: videos
            )
        }
    }
}
