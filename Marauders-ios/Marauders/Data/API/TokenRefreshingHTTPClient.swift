//
//  TokenRefreshingHTTPClient.swift
//  Marauders
//

import Foundation
import MaraudersAuth

/// The refresh behind a 401 could not be made or did not give an answer, so nothing is known about the session. A
/// caller gets this instead of the 401 it would have read as "signed out": the session is kept and the request can be
/// tried again later.
nonisolated struct SessionRefreshUnavailableError: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "The service is temporarily unavailable. Please try again.") }
}

/// Wraps an `HTTPClient` and heals a 401: a request that carried an access token and was rejected is sent once more
/// with a new one, so a session that has only outlived its access token goes on without the viewer noticing.
///
/// - Anything but a 401, and a 401 to a request without a Bearer token (a guest), goes back untouched.
/// - The refresher is asked for a token to replace the rejected one. A new token means the same request goes out once
///   more with it, and whatever that answers goes back, a second 401 included: it is reported through
///   `reportRejectedReplay`, because a session whose fresh token is rejected is over.
/// - A refusal gives back the original 401, so the session ends as it always did.
/// - A refresh that could not be made throws, and the caller never sees a 401. A transport error comes through as it
///   is, so a caller's own retry of transient failures still applies. Anything else is one typed error,
///   `SessionRefreshUnavailableError`.
///
/// An upload is replayed with the same parts: a 401 means the Worker applied nothing. A part that names a file (a clip)
/// is copied into the body again, so the replay sends the same bytes as long as the file is still there.
struct TokenRefreshingHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let refresher: any TokenRefreshing
    private let reportRejectedReplay: (@Sendable (_ accessToken: String) async -> Void)?

    /// - Parameter reportRejectedReplay: Told the new access token when a request sent again with it is rejected as
    ///   well. It runs before the 401 is handed back. A client above this one that reports 401s sees the old token of
    ///   the request it sent, which a session that has moved on to the new one ignores, so the new one is reported here.
    nonisolated init(
        base: any HTTPClient,
        refresher: any TokenRefreshing,
        reportRejectedReplay: (@Sendable (_ accessToken: String) async -> Void)? = nil
    ) {
        self.base = base
        self.refresher = refresher
        self.reportRejectedReplay = reportRejectedReplay
    }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        try await send(request) { try await base.data($0) }
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        try await upload(request, multipart: multipart, progress: nil)
    }

    /// A replay reports through the same `progress`, starting again from 0, so a caller sees the bar restart.
    nonisolated func upload(
        _ request: URLRequest,
        multipart: [HTTPMultipartPart],
        progress: UploadProgressHandler?
    ) async throws -> HTTPClientResponse {
        try await send(request) { try await base.upload($0, multipart: multipart, progress: progress) }
    }

    /// `perform` sends a request; the replay goes through it too, so an upload goes out again with the same parts.
    private nonisolated func send(
        _ request: URLRequest,
        perform: (URLRequest) async throws -> HTTPClientResponse
    ) async throws -> HTTPClientResponse {
        let response = try await perform(request)
        guard response.statusCode == 401, let rejectedToken = request.bearerToken else { return response }

        switch await refresher.refreshedAccessToken(replacing: rejectedToken) {
        case .refreshed(let newToken):
            var replay = request
            replay.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let answer = try await perform(replay)
            if answer.statusCode == 401 { await reportRejectedReplay?(newToken) }
            return answer
        case .rejected:
            return response
        case .unavailable(let error):
            if error is URLError { throw error }
            throw SessionRefreshUnavailableError()
        }
    }
}
