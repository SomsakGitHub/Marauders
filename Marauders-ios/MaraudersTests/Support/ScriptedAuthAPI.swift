//
//  ScriptedAuthAPI.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// The Worker's refresh route as a test scripts it: each call to `refreshTokens(using:)` gets the next prepared result,
/// after the gate when there is one. It keeps the calls and the refresh tokens they carried. The two other calls are not
/// scripted and fail.
///
/// nonisolated: Swift 6.4 would make a class that conforms to this MainActor-isolated protocol MainActor-isolated, but
/// the calls are counted from the refresher's task and read from the test's, which the lock makes safe.
nonisolated final class ScriptedAuthAPI: AuthAPIClientProtocol, @unchecked Sendable {
    /// What a call that was not scripted ends with.
    struct NothingScripted: Error {}

    private let lock = NSLock()
    private var results: [Result<AuthTokens, any Error>] = []
    private var given: [String] = []
    private let gate: SignOutGate?

    /// - Parameter gate: Holds every call until the test opens it. `SignOutGate` is a plain gate that any test can use;
    ///   it carries the name of the test that needed one first.
    init(gate: SignOutGate? = nil) {
        self.gate = gate
    }

    /// Prepares the answer to a later call. Answers are given in the order they were prepared.
    func enqueue(_ result: Result<AuthTokens, any Error>) {
        lock.withLock { results.append(result) }
    }

    /// How many times the Worker was asked, a call that is still held at the gate included.
    var refreshCalls: Int { lock.withLock { given.count } }

    /// The refresh token each call carried, in order.
    var refreshTokensGiven: [String] { lock.withLock { given } }

    /// Returns once `count` calls have been made. A test that never gets them is stopped by its time limit.
    func waitForCalls(_ count: Int) async {
        while refreshCalls < count, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        let result: Result<AuthTokens, any Error> = lock.withLock {
            given.append(refreshToken)
            return results.isEmpty ? .failure(NothingScripted()) : results.removeFirst()
        }
        await gate?.wait()
        // A transport whose task was cancelled ends with an error, whatever the Worker would have answered.
        try Task.checkCancellation()
        return try result.get()
    }

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        throw NothingScripted()
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw NothingScripted()
    }
}
