//
//  FeedAPIClient.swift
//  Marauders
//

import Foundation

struct FeedAPIResponse: Decodable, Sendable {
    let items: [FeedVideo]
}

enum FeedAPIError: LocalizedError, Equatable {
    case invalidLimit
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "Invalid number of clips requested"
        case .invalidResponse:
            return "Invalid API response format"
        case .serverError(let code):
            return "Server responded with status \(code)"
        }
    }
}

struct FeedAPIClient: Sendable {
    static let defaultMaxAttempts = 3

    private let session: URLSession
    private let maxAttempts: Int
    private let retryDelayNs: @Sendable (Int) -> UInt64

    init(
        session: URLSession = .shared,
        maxAttempts: Int = FeedAPIClient.defaultMaxAttempts
    ) {
        self.session = session
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNs = feedAPIProductionRetryDelayNanoseconds
    }

    init(
        session: URLSession,
        maxAttempts: Int,
        retryDelayNs: @escaping @Sendable (Int) -> UInt64
    ) {
        self.session = session
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNs = retryDelayNs
    }

    func fetchFeed(limit: Int = 20) async throws -> [FeedVideo] {
        var lastError: Error?

        for attempt in 0 ..< maxAttempts {
            do {
                return try await performFetchFeed(limit: limit)
            } catch {
                lastError = error
                guard attempt < maxAttempts - 1, FeedAPIRetryPolicy.isRetryable(error) else {
                    throw error
                }
                let delay = retryDelayNs(attempt)
                if delay > 0 {
                    AppLog.warning(
                        "api.feed",
                        "transient failure attempt=\(attempt + 1)/\(maxAttempts) retryInMs=\(delay / 1_000_000)"
                    )
                    try await Task.sleep(nanoseconds: delay)
                } else {
                    AppLog.warning("api.feed", "transient failure attempt=\(attempt + 1)/\(maxAttempts) retry")
                }
            }
        }

        throw lastError ?? FeedAPIError.invalidResponse
    }

    private func performFetchFeed(limit: Int) async throws -> [FeedVideo] {
        let requestURL = try APIConfiguration.feedRequestURL(limit: limit)
        AppLog.info("api.feed", "GET \(requestURL.absoluteString)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            AppLog.error("api.feed", "no HTTPURLResponse")
            throw FeedAPIError.invalidResponse
        }

        AppLog.info("api.feed", "status=\(http.statusCode) bytes=\(data.count)")

        guard (200 ... 299).contains(http.statusCode) else {
            AppLog.error("api.feed", "server error status=\(http.statusCode)")
            throw FeedAPIError.serverError(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(FeedAPIResponse.self, from: data)
            for item in decoded.items {
                guard item.streamURL.scheme?.lowercased() == "https" else {
                    AppLog.error("api.feed", "non-HTTPS stream URL in item \(item.id.uuidString)")
                    throw FeedAPIError.invalidResponse
                }
            }
            AppLog.info("api.feed", "items=\(decoded.items.count)")
            return decoded.items
        } catch let error as FeedAPIError {
            throw error
        } catch {
            AppLog.error("api.feed", "decode failed: \(error.localizedDescription)")
            throw FeedAPIError.invalidResponse
        }
    }
}
