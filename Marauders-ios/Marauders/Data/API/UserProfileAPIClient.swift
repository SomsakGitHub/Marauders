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
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: AlamofireHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
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

        let response = try await client.data(request)
        if response.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        guard response.isSuccess else {
            throw UserProfileAPIError.serverError(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: response.data).profile
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

        let response = try await client.data(request)
        if response.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        if response.statusCode == 400 {
            throw UserProfileAPIError.invalidHandle
        }
        guard response.isSuccess else {
            throw UserProfileAPIError.serverError(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(PublicResponse.self, from: response.data).profile
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

        let response = try await client.data(request)
        switch response.statusCode {
        case 409:
            throw UserProfileAPIError.handleTaken
        case 400:
            throw UserProfileAPIError.invalidHandle
        case 401:
            throw UserProfileAPIError.notAuthenticated
        case 200 ... 299:
            break
        default:
            throw UserProfileAPIError.serverError(response.statusCode)
        }

        struct UpdateResponse: Decodable { let handle: String }
        do {
            return try JSONDecoder().decode(UpdateResponse.self, from: response.data).handle
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

        let response = try await client.data(request)
        if response.statusCode == 404 {
            throw UserProfileAPIError.notFound
        }
        guard response.isSuccess else {
            throw UserProfileAPIError.serverError(response.statusCode)
        }
    }

    /// Uploads (or replaces) the signed-in user's avatar; returns the new URL.
    func uploadAvatar(imageData: Data, mimeType: String, filename: String) async throws -> URL {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserProfileAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.userAvatarURL()
        AppLog.info("api.profile", "POST \(requestURL.host ?? "?")/v1/users/me/avatar bytes=\(imageData.count)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let parts: [HTTPMultipartPart] = [
            .file(name: "file", filename: filename, mimeType: mimeType, data: imageData),
        ]
        let response = try await client.upload(request, multipart: parts)
        switch response.statusCode {
        case 401:
            throw UserProfileAPIError.notAuthenticated
        case 400:
            throw UserProfileAPIError.invalidHandle
        case 200 ... 299:
            break
        default:
            throw UserProfileAPIError.serverError(response.statusCode)
        }

        struct AvatarResponse: Decodable { let avatarURL: URL }
        do {
            return try JSONDecoder().decode(AvatarResponse.self, from: response.data).avatarURL
        } catch {
            throw UserProfileAPIError.invalidResponse
        }
    }

    /// Removes the signed-in user's avatar.
    func deleteAvatar() async throws {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserProfileAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.userAvatarURL()
        AppLog.info("api.profile", "DELETE \(requestURL.host ?? "?")/v1/users/me/avatar")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw UserProfileAPIError.notAuthenticated
        case 200 ... 299:
            break
        default:
            throw UserProfileAPIError.serverError(response.statusCode)
        }
    }

    private struct Response: Decodable {
        let handle: String?
        let country: String?
        let avatarURL: URL?
        let latitude: Double?
        let longitude: Double?
        let videoCount: Int
        let videos: [FeedVideo]

        var profile: UserProfile {
            UserProfile(
                handle: handle ?? "@marauders",
                country: country,
                avatarURL: avatarURL,
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
        let avatarURL: URL?
        let videoCount: Int
        let videos: [FeedVideo]

        var profile: PublicUserProfile {
            PublicUserProfile(
                handle: handle,
                country: country,
                avatarURL: avatarURL,
                videoCount: videoCount,
                videos: videos
            )
        }
    }
}
