//
//  SignOutSharingDoubles.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// A saved session as the Keychain keeps it. nonisolated: Swift 6.4 would make a class that conforms to these
/// MainActor-isolated protocols MainActor-isolated, but a stubbed network reads the token from its own thread while a
/// sign out clears it, which the lock makes safe.
nonisolated final class SignOutSessionStorage: AuthSessionStore, APIAccessTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedUserID: String?
    private var storedAccessToken: String?

    init(userID: String? = nil, accessToken: String? = nil) {
        storedUserID = userID
        storedAccessToken = accessToken
    }

    var userID: String? {
        get { lock.withLock { storedUserID } }
        set { lock.withLock { storedUserID = newValue } }
    }

    var accessToken: String? {
        get { lock.withLock { storedAccessToken } }
        set { lock.withLock { storedAccessToken = newValue } }
    }

    func loadUserID() -> String? { userID }
    func saveUserID(_ userID: String) throws { self.userID = userID }
    func clear() throws { userID = nil }

    func loadAccessToken() -> String? { accessToken }
    func saveAccessToken(_ token: String) throws { accessToken = token }
    func clearAccessToken() throws { accessToken = nil }
}

/// Holds a call until the test lets it go. A closed gate ignores cancellation, like a transport that is stuck.
actor SignOutGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// The Worker's location sharing as a sign out meets it: it remembers whether the viewer shares, notes every change it
/// is asked for together with what was left of the session at that moment, and can fail, answer late or never answer.
final class SignOutSharingRepository: LocationSharingRepository, @unchecked Sendable {
    struct Call: Equatable {
        let enabled: Bool
        /// What the saved session held when the call arrived.
        let accessToken: String?
        let userID: String?
    }

    /// What the Worker says about the viewer's sharing.
    var sharing: Bool
    /// The session the sign out is clearing; read when a call arrives, to tell whether it still had its token.
    var session: SignOutSessionStorage?
    /// Thrown by a change instead of answering.
    var failure: Error?
    /// A change waits here before it answers, and ignores cancellation while it does.
    var gate: SignOutGate?
    /// A change answers this late, but gives way to cancellation the way a `URLSession` request does.
    var delay: Duration?
    private(set) var calls: [Call] = []
    /// How many changes were cancelled while they waited for `delay`.
    private(set) var cancelledCalls = 0

    init(sharing: Bool = true) {
        self.sharing = sharing
    }

    func friendLocations() async throws -> FriendLocations {
        FriendLocations(sharing: sharing, friends: [])
    }

    func setSharing(_ enabled: Bool) async throws -> Bool {
        calls.append(Call(enabled: enabled, accessToken: session?.accessToken, userID: session?.userID))
        if let gate { await gate.wait() }
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                cancelledCalls += 1
                throw error
            }
        }
        if let failure { throw failure }
        sharing = enabled
        return enabled
    }
}

/// Why a call failed, with a marker that only one test's log line can carry.
struct SignOutSharingFailure: LocalizedError {
    let marker: String

    var errorDescription: String? { "the Worker said \(marker)" }
}
