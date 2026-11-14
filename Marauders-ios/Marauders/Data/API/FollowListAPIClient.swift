//
//  FollowListAPIClient.swift
//  Marauders
//

import Foundation

struct FollowListAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: URLSessionHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// One page of a profile's followers or of the accounts it follows, newest first. Only a signed-in viewer may ask:
    /// without a session nothing is sent.
    func fetchList(handle: String, kind: FollowListKind, cursor: String?, limit: Int) async throws -> FollowListPage {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw FollowListError.signInRequired
        }

        let requestURL = try APIConfiguration.followListURL(handle: handle, kind: kind, cursor: cursor, limit: limit)
        AppLog.info("api.follow-list", "GET \(requestURL.host ?? "?")/v1/users/<handle>/\(kind.rawValue)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw FollowListError.signInRequired
        case 404:
            throw FollowListError.notFound
        case 429:
            throw FollowListError.rateLimited
        case 200...299:
            break
        default:
            // A 400 lands here too: the app builds the handle and the cursor itself, so it is a bug or an older Worker.
            throw FollowListError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(ListResponse.self, from: response.data)
            return FollowListPage(entries: decoded.items.map(\.entry), nextCursor: decoded.nextCursor)
        } catch {
            AppLog.error("api.follow-list", "decode failed: \(error.localizedDescription)")
            throw FollowListError.invalidResponse
        }
    }

    private struct ListResponse: Decodable {
        let items: [Item]
        let nextCursor: String?
    }

    private struct Item: Decodable {
        let handle: String
        let avatarURL: String?
        let followedByViewer: Bool
        let isViewer: Bool

        var entry: FollowListEntry {
            FollowListEntry(
                handle: handle,
                avatarURL: Self.webAddress(avatarURL),
                followedByViewer: followedByViewer,
                isViewer: isViewer
            )
        }

        /// A picture address the app can load: http or https with a host. Anything else shows the placeholder instead of
        /// failing the page.
        private static func webAddress(_ raw: String?) -> URL? {
            guard
                let raw,
                let url = URL(string: raw),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host?.isEmpty == false
            else {
                return nil
            }
            return url
        }
    }
}
