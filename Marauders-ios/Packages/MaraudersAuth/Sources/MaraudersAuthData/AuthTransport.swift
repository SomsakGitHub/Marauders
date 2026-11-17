//
//  AuthTransport.swift
//  MaraudersAuthData
//

import Foundation

/// The answer to one request of the session module: the status and the body. It is plain data and on no actor, so a
/// transport can build it wherever it runs.
public nonisolated struct AuthTransportResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    var isSuccess: Bool {
        (200...299).contains(statusCode)
    }
}

/// Sends the session module's requests. The app supplies it, so the module shares the app's HTTP stack and brings none
/// of its own.
///
/// A status outside 2xx is an answer, not an error. A request that could not be sent or answered throws: a `URLError`,
/// or an error the transport marks with `AuthTransportFailure`.
public protocol AuthTransport: Sendable {
    func data(_ request: URLRequest) async throws -> AuthTransportResponse
}

/// Marks a transport's own errors that mean the Worker could not be reached. The token refresher asks once more after
/// one of them, as it does after a `URLError`.
public nonisolated protocol AuthTransportFailure: Error {}
