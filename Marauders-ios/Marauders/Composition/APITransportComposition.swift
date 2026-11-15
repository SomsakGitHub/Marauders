//
//  APITransportComposition.swift
//  Marauders
//

import Foundation

/// How the app's HTTP clients are layered, in one place, so every client that sends a session's token meets a 401 the
/// same way: a refresh first, and the end of the session only when the refresh cannot save it.
///
/// Listed from the outside in. `reporter` tells the session its token was rejected, `refresh` trades a rejected token
/// for a new one and replays the request, `retry` repeats a read that failed for a transient reason.
nonisolated enum APITransportComposition {
    /// Every client but the feed: reporter ← refresh ← retry ← base. The replay of a request goes through the retry
    /// layer too, so a read that is rejected, refreshed and then met by a 503 is still tried again.
    ///
    /// - Parameter reportRejected: Told the access token of a request the Worker rejected for good. It goes to the
    ///   reporter, and to the refresh layer, which reports the new token when the replay is rejected as well.
    nonisolated static func api(
        base: any HTTPClient,
        refresher: any TokenRefreshing,
        reportRejected: @escaping @Sendable (String) async -> Void
    ) -> any HTTPClient {
        RejectedSessionReportingHTTPClient(
            base: TokenRefreshingHTTPClient(
                base: RetryingHTTPClient(base: base), refresher: refresher, reportRejectedReplay: reportRejected),
            report: reportRejected)
    }

    /// The feed repeats its own reads (`FeedAPIClient`), so it gets no second layer of retries: reporter ← refresh ←
    /// base.
    nonisolated static func feed(
        base: any HTTPClient,
        refresher: any TokenRefreshing,
        reportRejected: @escaping @Sendable (String) async -> Void
    ) -> any HTTPClient {
        RejectedSessionReportingHTTPClient(
            base: TokenRefreshingHTTPClient(base: base, refresher: refresher, reportRejectedReplay: reportRejected),
            report: reportRejected)
    }

    /// For the callers that run without a screen to sign out from (the location sent while the app is closed, the AI
    /// audio shared between viewers): refresh ← base. A 401 that a refresh cannot heal comes back to the caller, which
    /// decides what it means; nothing here ends the session.
    nonisolated static func quiet(base: any HTTPClient, refresher: any TokenRefreshing) -> any HTTPClient {
        TokenRefreshingHTTPClient(base: base, refresher: refresher)
    }
}
