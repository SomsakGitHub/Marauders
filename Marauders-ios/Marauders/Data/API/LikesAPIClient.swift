//
//  LikesAPIClient.swift
//  Marauders
//

import Foundation

struct LikesAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: URLSessionHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// PUT likes the clip, DELETE takes the like back; both are safe to repeat.
    func setLiked(_ liked: Bool, videoID: UUID) async throws -> ClipLikeState {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw ClipLikeError.signInRequired
        }

        let requestURL = try APIConfiguration.likeURL(videoID: videoID)
        AppLog.info("api.likes", "\(liked ? "PUT" : "DELETE") \(requestURL.host ?? "?")/v1/videos/<id>/like")

        var request = URLRequest(url: requestURL)
        request.httpMethod = liked ? "PUT" : "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw ClipLikeError.signInRequired
        case 404:
            throw ClipLikeError.notFound
        case 429:
            throw ClipLikeError.rateLimited
        case 200...299:
            break
        default:
            throw ClipLikeError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(LikeResponse.self, from: response.data)
            return ClipLikeState(liked: decoded.liked, count: max(0, decoded.likeCount))
        } catch {
            AppLog.error("api.likes", "decode failed: \(error.localizedDescription)")
            throw ClipLikeError.invalidResponse
        }
    }

    private struct LikeResponse: Decodable {
        let liked: Bool
        let likeCount: Int
    }
}
