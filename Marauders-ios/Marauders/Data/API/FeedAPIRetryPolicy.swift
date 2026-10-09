//
//  FeedAPIRetryPolicy.swift
//  Marauders
//

import Foundation

nonisolated func feedAPIProductionRetryDelayNanoseconds(attempt: Int) -> UInt64 {
    let base: UInt64 = 500_000_000
    let multiplier = UInt64(1 << min(attempt, 2))
    return min(base * multiplier, 2_000_000_000)
}

enum FeedAPIRetryPolicy {
    /// Transient failures safe to retry for idempotent `GET /v1/feed`.
    static func isRetryable(_ error: Error) -> Bool {
        if let feedError = error as? FeedAPIError {
            return feedError.isRetryable
        }
        if let urlError = error as? URLError {
            return urlError.isTransientFeedFailure
        }
        return false
    }
}

extension FeedAPIError {
    var isRetryable: Bool {
        switch self {
        case .serverError(let statusCode):
            return [502, 503, 504].contains(statusCode)
        case .invalidLimit, .invalidResponse:
            return false
        }
    }
}

extension URLError {
    var isTransientFeedFailure: Bool {
        switch code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
