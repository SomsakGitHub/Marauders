//
//  FollowsAPIClient.swift
//  Marauders
//

import Foundation

struct FollowsAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: AlamofireHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// PUT follows the account, DELETE stops following it; both are safe to repeat.
    func setFollowing(_ following: Bool, handle: String) async throws -> UserFollowChange {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw UserFollowError.signInRequired
        }

        let requestURL = try APIConfiguration.followURL(handle: handle)
        AppLog.info("api.follows", "\(following ? "PUT" : "DELETE") \(requestURL.host ?? "?")/v1/users/<handle>/follow")

        var request = URLRequest(url: requestURL)
        request.httpMethod = following ? "PUT" : "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw UserFollowError.signInRequired
        // A handle the Worker cannot read (400) names no account either.
        case 400, 404:
            throw UserFollowError.notFound
        case 422:
            throw UserFollowError.cannotFollowSelf
        case 429:
            throw UserFollowError.rateLimited
        case 200 ... 299:
            break
        default:
            throw UserFollowError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(FollowResponse.self, from: response.data)
            return UserFollowChange(
                following: decoded.following,
                followerCount: max(0, decoded.followerCount),
                viewerFollowingCount: max(0, decoded.viewerFollowingCount)
            )
        } catch {
            AppLog.error("api.follows", "decode failed: \(error.localizedDescription)")
            throw UserFollowError.invalidResponse
        }
    }

    private struct FollowResponse: Decodable {
        let following: Bool
        let followerCount: Int
        let viewerFollowingCount: Int
    }
}
