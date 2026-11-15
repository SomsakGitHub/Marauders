//
//  RetryingHTTPClient.swift
//  Marauders
//

import Foundation

/// Wraps an `HTTPClient` and repeats a request that failed for a transient reason.
///
/// Only idempotent reads (GET, HEAD) are repeated, and never an upload: a repeat of a write could be applied twice.
/// A request is repeated when the network dropped it (offline, timed out, connection lost, DNS) or the Worker
/// answered 502, 503 or 504. Any other answer, a 401 and a cancellation included, goes back at once.
struct RetryingHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let maxAttempts: Int
    private let delayNanoseconds: @Sendable (_ attempt: Int) -> UInt64

    /// - Parameters:
    ///   - maxAttempts: Total tries including the first; 1 or less means no retry.
    ///   - delayNanoseconds: Pause before the next try; `attempt` is 0 after the first failure.
    nonisolated init(
        base: any HTTPClient,
        maxAttempts: Int = 3,
        delayNanoseconds: @escaping @Sendable (_ attempt: Int) -> UInt64 = feedAPIProductionRetryDelayNanoseconds
    ) {
        self.base = base
        self.maxAttempts = max(1, maxAttempts)
        self.delayNanoseconds = delayNanoseconds
    }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        guard Self.isIdempotent(request) else { return try await base.data(request) }

        for attempt in 0..<maxAttempts - 1 {
            do {
                let response = try await base.data(request)
                guard [502, 503, 504].contains(response.statusCode) else { return response }
            } catch {
                guard Self.isTransient(error) else { throw error }
            }
            let path = request.url?.path() ?? ""
            await AppLog.warning("api.retry", "transient failure attempt=\(attempt + 1)/\(maxAttempts) \(path)")
            let delay = delayNanoseconds(attempt)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        }
        return try await base.data(request)
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        try await upload(request, multipart: multipart, progress: nil)
    }

    nonisolated func upload(
        _ request: URLRequest,
        multipart: [HTTPMultipartPart],
        progress: UploadProgressHandler?
    ) async throws -> HTTPClientResponse {
        try await base.upload(request, multipart: multipart, progress: progress)
    }

    private nonisolated static func isIdempotent(_ request: URLRequest) -> Bool {
        ["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased())
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        (error as? URLError)?.isTransientFeedFailure ?? false
    }
}
