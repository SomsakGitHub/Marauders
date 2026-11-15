//
//  HTTPClient+GuestFallback.swift
//  Marauders
//

import Foundation

extension HTTPClient {
    /// Sends a public read that works for a guest too, so a session that cannot be used never keeps the viewer from it.
    ///
    /// A request without a Bearer token is sent as it is. One with a token is sent first, and goes out once more
    /// without the `Authorization` header when the Worker answers 401, or when the call throws
    /// `SessionRefreshUnavailableError` (a 401 whose refresh could not be made: the session may still be alive, only it
    /// cannot be used right now). Anything else, a transport error included, comes back as it is.
    ///
    /// - Parameter logCategory: The caller's log category, for the line that says the read fell back to a guest.
    func dataFallingBackToGuest(_ request: URLRequest, logCategory: String) async throws -> HTTPClientResponse {
        guard request.bearerToken != nil else { return try await data(request) }

        do {
            let response = try await data(request)
            guard response.statusCode == 401 else { return response }
            // The Worker rejects a bad session even on a public read, so read as a guest instead of failing.
            AppLog.warning(logCategory, "session rejected, reading as guest")
        } catch is SessionRefreshUnavailableError {
            AppLog.warning(logCategory, "session unavailable, reading as guest")
        }

        var guest = request
        guest.setValue(nil, forHTTPHeaderField: "Authorization")
        return try await data(guest)
    }
}
