//
//  UITestRejectedSession.swift
//  Marauders
//

import Foundation

/// UI tests only (`UITEST` plus `UITEST_REJECTED_SESSION`): a signed-in viewer whose session the Worker has rejected.
///
/// The profile then goes through its real API client over `UITestRejectingHTTPClient`, so the 401 reaches the same
/// code a real one does. Both stores live in memory: the sign-out that 401 causes must never touch the Keychain of
/// the app installed on the device.
nonisolated final class UITestRejectedSession: AuthSessionStore, APIAccessTokenStore, @unchecked Sendable {
    static let launchArgument = "UITEST_REJECTED_SESSION"
    /// Long enough to pass `APIAccessTokenFormat.isValid`, so the clients attach it.
    static let accessToken = "ui-test-rejected-session-token"

    @MainActor static var isRequested: Bool {
        AppRuntimeConfiguration.isUITesting && ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private let lock = NSLock()
    private var userID: String? = "ui-test-user"
    private var token: String? = UITestRejectedSession.accessToken

    func loadUserID() -> String? { lock.withLock { userID } }
    func saveUserID(_ userID: String) throws { lock.withLock { self.userID = userID } }
    func clear() throws { lock.withLock { userID = nil } }

    func loadAccessToken() -> String? { lock.withLock { token } }
    func saveAccessToken(_ token: String) throws { lock.withLock { self.token = token } }
    func clearAccessToken() throws { lock.withLock { token = nil } }
}

/// Answers 401 to any request that carries a token, as the Worker does for a session it rejects, and 404 to the rest.
struct UITestRejectingHTTPClient: HTTPClient {
    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        if request.value(forHTTPHeaderField: "Authorization") != nil {
            return Self.rejection
        }
        return HTTPClientResponse(data: Data(), statusCode: 404)
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        Self.rejection
    }

    private nonisolated static let rejection = HTTPClientResponse(
        data: Data(#"{"error":"invalid session"}"#.utf8),
        statusCode: 401
    )
}
