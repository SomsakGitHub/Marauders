//
//  DevAuthAPIClient.swift
//  Marauders
//

#if DEBUG
import Foundation

/// Signs in a named test user through `/v1/auth/dev`, for the Simulator where Sign in with Apple has no account.
/// The Worker answers 404 unless `DEV_LOGIN_SECRET` is set there. Compiled into debug builds only.
enum DevLogin {
    static let userIDPrefix = "dev:"
    private static let secretKey = "MARAUDERS_DEV_LOGIN_SECRET"
    private static let labelKey = "MARAUDERS_DEV_LOGIN_LABEL"

    /// Present only when the debug app was launched with the secret in its environment
    /// (`SIMCTL_CHILD_MARAUDERS_DEV_LOGIN_SECRET=… xcrun simctl launch …`); it is never stored in the project.
    static var secret: String? {
        #if targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment[secretKey], !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    /// Which test user to become; each label is one stable account.
    static var label: String {
        ProcessInfo.processInfo.environment[labelKey].flatMap { $0.isEmpty ? nil : $0 } ?? "simulator"
    }

    static var isAvailable: Bool { secret != nil }

    static func isDevUserID(_ userID: String) -> Bool {
        userID.hasPrefix(userIDPrefix)
    }
}

struct DevAuthAPIClient: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient = AlamofireHTTPClient()) {
        self.client = client
    }

    func accessToken(secret: String, label: String, countryCode: String) async throws -> String {
        var request = URLRequest(url: try APIConfiguration.devAuthURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode([
            "secret": secret,
            "label": label,
            "country": countryCode.uppercased()
        ])

        AppLog.info("api.auth", "POST /v1/auth/dev")

        let response = try await client.data(request)
        guard response.isSuccess else {
            throw AuthAPIError.serverError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(AuthAPIResponse.self, from: response.data)
        guard APIAccessTokenFormat.isValid(decoded.accessToken) else {
            throw AuthAPIError.invalidResponse
        }
        return decoded.accessToken
    }
}
#endif
