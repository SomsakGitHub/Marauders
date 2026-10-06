//
//  APIConfiguration.swift
//  Marauders
//

import Foundation

enum APIConfiguration {
    private static let feedLimitDefault = 20
    private static let feedLimitMax = 50

    /// HTTPS origin of the Worker (no trailing slash). Set via Info.plist `MARAUDERS_API_BASE_URL`.
    static func apiBaseURL() throws -> URL {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "MARAUDERS_API_BASE_URL") as? String
        else {
            throw APIConfigurationError.missingBaseURL
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw APIConfigurationError.invalidBaseURL
        }

        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw APIConfigurationError.invalidBaseURL
        }

        if url.path != "/" && !url.path.isEmpty {
            throw APIConfigurationError.invalidBaseURL
        }

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
}

enum APIConfigurationError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "ตั้งค่า MARAUDERS_API_BASE_URL ใน Info.plist (URL ของ Cloudflare Worker)"
        case .invalidBaseURL:
            return "MARAUDERS_API_BASE_URL ต้องเป็น https:// โดยไม่มี path"
        }
    }
}
