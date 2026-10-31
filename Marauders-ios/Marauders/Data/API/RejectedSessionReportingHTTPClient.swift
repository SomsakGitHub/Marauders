//
//  RejectedSessionReportingHTTPClient.swift
//  Marauders
//

import Foundation

/// Wraps an `HTTPClient` and reports every 401 the Worker answers to a request that carried an access token.
///
/// This is the one place the app learns that its session has ended on the server. The response goes on to the
/// caller untouched, so each API client keeps mapping 401 to its own error, and a public read keeps its retry as a
/// guest. A request without a bearer token (a guest, or the sign-in exchange itself) is never reported.
struct RejectedSessionReportingHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let report: @Sendable (_ accessToken: String) async -> Void

    /// `report` runs before the response is handed back, so by the time a client throws its own error for the
    /// 401 the session has already been ended.
    nonisolated init(base: any HTTPClient, report: @escaping @Sendable (_ accessToken: String) async -> Void) {
        self.base = base
        self.report = report
    }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        let response = try await base.data(request)
        await reportIfRejected(request, response)
        return response
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        let response = try await base.upload(request, multipart: multipart)
        await reportIfRejected(request, response)
        return response
    }

    private nonisolated func reportIfRejected(_ request: URLRequest, _ response: HTTPClientResponse) async {
        guard response.statusCode == 401, let accessToken = Self.bearerToken(of: request) else { return }
        await report(accessToken)
    }

    private nonisolated static func bearerToken(of request: URLRequest) -> String? {
        let scheme = "Bearer "
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix(scheme) else { return nil }
        let token = header.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
