//
//  AccountDeletionAPIClient.swift
//  Marauders
//

import Foundation

/// `DELETE /v1/users/me`: deletes the signed-in account on the Worker.
struct AccountDeletionAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: URLSessionHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// `authorizationCode` is the one-time code of the Sign in with Apple sheet the person just confirmed; a test account
    /// of the debug sign-in has no Apple grant and sends none. Every answer of the Worker becomes an
    /// `AccountDeletionError`. A request that could not reach the Worker (offline, timed out) throws its `URLError` as it
    /// is: the view model explains it.
    func deleteAccount(authorizationCode: String?) async throws {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw AccountDeletionError.signInRequired
        }
        let requestURL = try APIConfiguration.userProfileURL()
        // The code is single-use and secret: the log says whether one went with the request, never what it was.
        AppLog.info(
            "api.account", "DELETE \(requestURL.host ?? "?")/v1/users/me withCode=\(authorizationCode != nil)")

        var body: [String: String] = [:]
        if let authorizationCode {
            body["authorizationCode"] = authorizationCode
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        // The Worker asks Apple, deletes the clips' files and then the rows before it answers.
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await client.data(request)
        switch response.statusCode {
        case 200...299:
            return
        case 400:
            throw AccountDeletionError.appleNotConfirmed
        case 401:
            throw AccountDeletionError.signInRequired
        case 403:
            throw AccountDeletionError.wrongAppleAccount
        case 405, 503:
            throw AccountDeletionError.notAvailable
        case 409:
            throw Self.conflict(in: response.data)
        case 429:
            throw AccountDeletionError.rateLimited
        default:
            throw AccountDeletionError.couldNotFinish
        }
    }

    /// The 409 says how many clips one deletion takes. An answer that does not say it in a way the person could be told
    /// is the general failure.
    private static func conflict(in data: Data) -> AccountDeletionError {
        struct Conflict: Decodable { let limit: Int }
        guard let limit = (try? JSONDecoder().decode(Conflict.self, from: data))?.limit, limit > 0 else {
            return .couldNotFinish
        }
        return .tooManyClips(limit: limit)
    }
}
