//
//  APIConfiguration.swift
//  Marauders
//

import Foundation

enum APIConfiguration {
    private static let feedLimitDefault = 20
    private static let feedLimitMax = 50
    private static let configKey = "MARAUDERS_API_BASE_URL"

    /// HTTPS origin of the Worker (no trailing slash).
    /// Sources: `APIConfiguration.plist` in bundle → Info.plist → Build Settings `INFOPLIST_KEY_MARAUDERS_API_BASE_URL`.
    static func apiBaseURL() throws -> URL {
        guard let raw = resolveBaseURLString(), !raw.isEmpty else {
            AppLog.error("config", "\(configKey) missing (plist + Info.plist)")
            throw APIConfigurationError.missingBaseURL
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            AppLog.error("config", "invalid URL string")
            throw APIConfigurationError.invalidBaseURL
        }

        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw APIConfigurationError.invalidBaseURL
        }

        if url.path != "/" && !url.path.isEmpty {
            throw APIConfigurationError.invalidBaseURL
        }

        AppLog.info("config", "api base host=\(host)")
        return url
    }

    static func feedRequestURL(limit: Int = feedLimitDefault) throws -> URL {
        guard limit >= 1, limit <= feedLimitMax else {
            throw FeedAPIError.invalidLimit
        }

        let base = try apiBaseURL()
        var components = URLComponents(url: base.appending(path: "v1/feed"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
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

    private static func resolveBaseURLString() -> String? {
        if let fromPlist = bundledConfigValue() {
            AppLog.info("config", "loaded base URL from APIConfiguration.plist")
            return fromPlist
        }
        if let fromInfo = Bundle.main.object(forInfoDictionaryKey: configKey) as? String {
            AppLog.info("config", "loaded base URL from Info.plist")
            return fromInfo
        }
        return nil
    }

    private static func bundledConfigValue() -> String? {
        guard
            let url = Bundle.main.url(forResource: "APIConfiguration", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let value = plist[configKey] as? String
        else {
            return nil
        }
        return value
    }
}

enum APIConfigurationError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "API URL not found — check APIConfiguration.plist in the project"
        case .invalidBaseURL:
            return "API URL must be https:// with no path"
        }
    }
}
