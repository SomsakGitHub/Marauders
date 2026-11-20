//
//  APIConfiguration.swift
//  Marauders
//

import Foundation

enum APIConfiguration {
    private static let feedLimitDefault = 20
    private static let feedLimitMax = 50
    /// The Worker's `COMMENT_LIMIT_MAX`.
    private static let commentLimitMax = 50
    /// The Worker's `FEED_LIMIT_MAX`, which the follower and following lists share.
    private static let followListLimitMax = 50

    /// HTTPS origin of the Worker (no trailing slash), from `APIBaseURL`: the `MARAUDERS_API_BASE_URL` key of
    /// Info.plist (production in a Release build and, while there is one backend, in a Debug build too), or in a Debug
    /// build an environment variable of that name. Logs the host and the source on every use, which every request goes
    /// through.
    static func apiBaseURL() throws -> URL {
        do {
            let base = try APIBaseURL.resolved()
            AppLog.info("config", "api base host=\(base.summary)")
            return base.url
        } catch APIConfigurationError.missingBaseURL {
            AppLog.error("config", "\(APIBaseURL.configKey) missing (Info.plist)")
            throw APIConfigurationError.missingBaseURL
        } catch {
            AppLog.error("config", "\(APIBaseURL.configKey) is not an https URL without a path")
            throw error
        }
    }

    static func feedRequestURL(
        limit: Int = feedLimitDefault,
        cursor: UUID? = nil,
        country: String? = nil,
        forMap: Bool = false
    ) throws -> URL {
        guard limit >= 1, limit <= feedLimitMax else {
            throw FeedAPIError.invalidLimit
        }

        let base = try apiBaseURL()
        var components = URLComponents(
            url: base.appending(path: forMap ? "v1/map/clips" : "v1/feed"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor.uuidString))
        }
        if let country, !country.isEmpty {
            queryItems.append(URLQueryItem(name: "country", value: country.uppercased()))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    static func videoUploadURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/videos", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    // The auth routes (`v1/auth/apple`, `/refresh`, `/signout`, `/dev`) are formed by the session module from
    // `apiBaseURL()`: see `AuthModuleBridge` and `Packages/MaraudersAuth`.

    static func userLocationURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/users/me/location", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    static func userProfileURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/users/me", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// Signed-in user's avatar upload/delete endpoint.
    static func userAvatarURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/users/me/avatar", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// Public profile for a `@handle` (no authentication required).
    static func publicUserProfileURL(handle: String) throws -> URL {
        let base = try apiBaseURL()
        let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        guard let url = URL(string: "v1/users/\(encoded)", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// Where the viewer's mutual followers who share their location were last (GET, Bearer).
    static func friendLocationsURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/users/me/friend-locations", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// The viewer's location sharing switch (PUT `{ enabled }`, Bearer).
    static func locationSharingURL() throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/users/me/location-sharing", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// The viewer's follow of the account with `handle`: PUT follows it, DELETE stops following it.
    static func followURL(handle: String) throws -> URL {
        let base = try apiBaseURL()
        let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        guard let url = URL(string: "v1/users/\(encoded)/follow", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// The accounts that follow `handle` (`.followers`) or that it follows (`.following`): GET, newest first (`limit`,
    /// `cursor`), signed-in viewers only.
    static func followListURL(handle: String, kind: FollowListKind, cursor: String? = nil, limit: Int? = nil) throws
        -> URL
    {
        let base = try apiBaseURL()
        let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        guard
            let pathURL = URL(string: "v1/users/\(encoded)/\(kind.rawValue)", relativeTo: base),
            var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: true)
        else {
            throw APIConfigurationError.invalidBaseURL
        }
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), followListLimitMax))))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    static func deleteVideoURL(id: UUID) throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/videos/\(id.uuidString)", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// A clip's comments: GET lists them newest first (`limit`, `cursor`), POST adds one.
    static func commentsURL(videoID: UUID, limit: Int? = nil, cursor: UUID? = nil) throws -> URL {
        let base = try apiBaseURL()
        var components = URLComponents(
            url: base.appending(path: "v1/videos/\(videoID.uuidString)/comments"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), commentLimitMax))))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor.uuidString))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// One comment, for DELETE by its author or the clip's owner.
    static func commentURL(videoID: UUID, commentID: UUID) throws -> URL {
        let base = try apiBaseURL()
        guard
            let url = URL(
                string: "v1/videos/\(videoID.uuidString)/comments/\(commentID.uuidString)",
                relativeTo: base
            )
        else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }

    /// The viewer's like on a clip: PUT adds it, DELETE takes it back.
    static func likeURL(videoID: UUID) throws -> URL {
        let base = try apiBaseURL()
        guard let url = URL(string: "v1/videos/\(videoID.uuidString)/like", relativeTo: base) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }
}
