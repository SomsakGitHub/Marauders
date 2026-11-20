//
//  APIBaseURL.swift
//  Marauders
//

import Foundation

/// Where a base URL came from.
enum APIBaseURLSource: Equatable, Sendable {
    /// The `MARAUDERS_API_BASE_URL` key of Info.plist, which the build setting of the same name fills.
    case configured
    /// The environment variable of the same name, read in a Debug build only.
    case override
}

/// The Worker's origin and where it came from: the one place that decides which Worker this run talks to.
///
/// It sits in `Shared` because the Debug log screen (Presentation) and the dev login (Shared) have to ask which Worker
/// that is, and neither may name a Data type. `APIConfiguration` (Data) forms every request URL from it.
///
/// The value comes from the `MARAUDERS_API_BASE_URL` key of Info.plist, which the build fills from the build setting
/// of the same name: production's URL in a Release build and, while there is one backend (ADR 010), in a Debug build
/// too. A Debug build also accepts an environment variable of that name as an override; a Release build never reads
/// the process environment.
struct APIBaseURL: Equatable, Sendable {
    let url: URL
    let source: APIBaseURLSource

    /// The Info.plist key, the build setting and the Debug environment variable all carry this name.
    static let configKey = "MARAUDERS_API_BASE_URL"

    /// The rule behind `resolved()`, without a bundle or a process environment. A non-blank `override` wins and is
    /// validated: an invalid one throws and never falls back to `configured`, because a run that quietly talks to
    /// another Worker than the one asked for is worse than a run that stops. A blank override counts as none. A blank
    /// or missing `configured` with no override throws `missingBaseURL`.
    static func resolve(configured: String?, override: String?) throws -> APIBaseURL {
        if let override = nonBlank(override) {
            return APIBaseURL(url: try validatedURL(override), source: .override)
        }
        guard let configured = nonBlank(configured) else {
            throw APIConfigurationError.missingBaseURL
        }
        return APIBaseURL(url: try validatedURL(configured), source: .configured)
    }

    /// The Worker this run talks to, and which source gave it. It logs nothing, so a view or `DevLogin` can ask for it
    /// freely (the log screen shows the log it would otherwise be writing to); `APIConfiguration.apiBaseURL()` logs
    /// the host and the source.
    static func resolved() throws -> APIBaseURL {
        try resolved(
            configured: Bundle.main.object(forInfoDictionaryKey: configKey) as? String,
            environment: ProcessInfo.processInfo.environment)
    }

    /// `resolved()` with its two inputs given. Only a Debug build reads `environment`: nothing in the process can
    /// point a Release app at another Worker.
    static func resolved(configured: String?, environment: [String: String]) throws -> APIBaseURL {
        #if DEBUG
            let override = environment[configKey]
        #else
            let override: String? = nil
        #endif
        return try resolve(configured: configured, override: override)
    }

    /// `"<host> (configured)"` or `"<host> (override)"`, for the log and the Debug log screen.
    var summary: String {
        let sourceName =
            switch source {
            case .configured: "configured"
            case .override: "override"
            }
        return "\(url.host ?? "?") (\(sourceName))"
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// An https origin with a host and no path beyond `/`.
    private static func validatedURL(_ trimmed: String) throws -> URL {
        guard let url = URL(string: trimmed) else {
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
}

enum APIConfigurationError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "API URL not found — check the MARAUDERS_API_BASE_URL build setting"
        case .invalidBaseURL:
            return "API URL must be https:// with no path"
        }
    }
}
