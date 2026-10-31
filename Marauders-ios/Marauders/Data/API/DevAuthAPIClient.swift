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

    /// The debug app's launch environment (`SIMCTL_CHILD_MARAUDERS_DEV_LOGIN_SECRET=… xcrun simctl launch …`), else
    /// the Worker's own `DEV_LOGIN_SECRET` in `backend/.dev.vars` of this checkout. It is never stored in the project.
    static var secret: String? {
        #if targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment[secretKey], !value.isEmpty { return value }
        return localWorkerSecret
        #else
        return nil
        #endif
    }

    #if targetEnvironment(simulator)
    /// A Simulator app can read the Mac's disk, and this source file's path leads to the checkout's git-ignored
    /// `backend/.dev.vars`, so a plain Run in Xcode is enough.
    private static let localWorkerSecret: String? = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // DevAuthAPIClient.swift, API, Data, Marauders, Marauders-ios
        let devVars = root.appendingPathComponent("backend/.dev.vars")
        guard let contents = try? String(contentsOf: devVars, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DEV_LOGIN_SECRET=") else { continue }
            let value = trimmed.dropFirst("DEV_LOGIN_SECRET=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }()
    #endif

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
