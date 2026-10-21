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

    private let client: HTTPClient
    private let maxAttempts: Int
    private let retryDelayNs: @Sendable (Int) -> UInt64

    init(
        session: URLSession = .shared,
        maxAttempts: Int = FeedAPIClient.defaultMaxAttempts
    ) {
        self.init(client: AlamofireHTTPClient(session: session), maxAttempts: maxAttempts)
    }

    init(
        client: HTTPClient,
        maxAttempts: Int = FeedAPIClient.defaultMaxAttempts
    ) {
        self.client = client
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNs = feedAPIProductionRetryDelayNanoseconds
    }

    init(
        session: URLSession,
        maxAttempts: Int,
        retryDelayNs: @escaping @Sendable (Int) -> UInt64
    ) {
        self.init(client: AlamofireHTTPClient(session: session), maxAttempts: maxAttempts, retryDelayNs: retryDelayNs)
    }

    init(
        client: HTTPClient,
        maxAttempts: Int,
        retryDelayNs: @escaping @Sendable (Int) -> UInt64
    ) {
        self.client = client
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNs = retryDelayNs
    }

    func fetchFeed(limit: Int = 20, cursor: UUID? = nil, country: String? = nil) async throws -> FeedPage {
        var lastError: Error?

        for attempt in 0 ..< maxAttempts {
            do {
                return try await performFetchFeed(limit: limit, cursor: cursor, country: country)
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

    private func performFetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage {
        let requestURL = try APIConfiguration.feedRequestURL(limit: limit, cursor: cursor, country: country)
        AppLog.info("api.feed", "GET \(requestURL.absoluteString)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let response = try await client.data(request)

        AppLog.info("api.feed", "status=\(response.statusCode) bytes=\(response.data.count)")

        guard response.isSuccess else {
            AppLog.error("api.feed", "server error status=\(response.statusCode)")
            throw FeedAPIError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(FeedAPIResponse.self, from: response.data)
            for item in decoded.items {
                guard item.streamURL.scheme?.lowercased() == "https" else {
                    AppLog.error("api.feed", "non-HTTPS stream URL in item \(item.id.uuidString)")
                    throw FeedAPIError.invalidResponse
                }
            }
            AppLog.info("api.feed", "items=\(decoded.items.count)")
            let hasMore = decoded.items.count >= limit
            return FeedPage(items: decoded.items, hasMore: hasMore)
        } catch let error as FeedAPIError {
            throw error
        } catch {
            AppLog.error("api.feed", "decode failed: \(error.localizedDescription)")
            throw FeedAPIError.invalidResponse
        }
    }
}
