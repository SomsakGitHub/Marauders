import Foundation
import Security
import Testing

@testable import Marauders
@testable import MaraudersAuth
@testable import MaraudersAuthData

/// A store that implements only `load`, as every in-memory one does, can always be read. Its read follows what it
/// holds, so a session kept in memory is restored and ended like one in the Keychain.
@MainActor
struct InMemoryStoreReadTests {
    @Test func aStoreWithoutAReadOfItsOwnAnswersFromWhatItHolds() throws {
        let session = UITestRejectedSession()
        let accessToken = String(repeating: "a", count: 32)
        let refreshToken = String(repeating: "r", count: 43)
        try session.saveUserID("001234.abcdef.5678")
        try session.saveAccessToken(accessToken)
        try session.saveRefreshToken(refreshToken)

        #expect(session.readUserID() == .value("001234.abcdef.5678"))
        #expect(session.readAccessToken() == .value(accessToken))
        #expect(session.readRefreshToken() == .value(refreshToken))

        try session.clear()
        try session.clearAccessToken()
        try session.clearRefreshToken()

        #expect(session.readUserID() == .missing)
        #expect(session.readAccessToken() == .missing)
        #expect(session.readRefreshToken() == .missing)
    }
}

/// What the three Keychain stores answer to a read. A Keychain that cannot be read is not an empty one: a caller that
/// took the first for the second would end a session that is still stored.
@MainActor
struct KeychainStoreReadTests {
    private static let accessToken = String(repeating: "a", count: 32)
    private static let refreshToken = String(repeating: "r", count: 43)
    private static let userID = "001234.abcdef.5678"

    @MainActor
    private struct Stores {
        var accessToken: KeychainAPIAccessTokenStore
        var refreshToken: KeychainAPIRefreshTokenStore
        var session: KeychainAuthSessionStore

        func clear() {
            try? accessToken.clearAccessToken()
            try? refreshToken.clearRefreshToken()
            try? session.clear()
        }
    }

    /// The three stores of a service no other test uses. With a `reader` they read through it, not the real Keychain.
    private static func stores(reader: KeychainItemReader? = nil) -> Stores {
        let service = "test.read." + UUID().uuidString
        var stores = Stores(
            accessToken: KeychainAPIAccessTokenStore(service: service),
            refreshToken: KeychainAPIRefreshTokenStore(service: service),
            session: KeychainAuthSessionStore(service: service))
        if let reader {
            stores.accessToken.reader = reader
            stores.refreshToken.reader = reader
            stores.session.reader = reader
        }
        return stores
    }

    // MARK: the real Keychain

    @Test func eachStoreReadsTheValueItSaved() throws {
        let stores = Self.stores()
        defer { stores.clear() }
        try stores.accessToken.saveAccessToken(Self.accessToken)
        try stores.refreshToken.saveRefreshToken(Self.refreshToken)
        try stores.session.saveUserID(Self.userID)

        #expect(stores.accessToken.readAccessToken() == .value(Self.accessToken))
        #expect(stores.refreshToken.readRefreshToken() == .value(Self.refreshToken))
        #expect(stores.session.readUserID() == .value(Self.userID))
    }

    @Test func aStoreThatHoldsNothingAnswersMissing() {
        let stores = Self.stores()

        #expect(stores.accessToken.readAccessToken() == .missing)
        #expect(stores.refreshToken.readRefreshToken() == .missing)
        #expect(stores.session.readUserID() == .missing)
    }

    // MARK: a Keychain that refuses the read

    /// -25308 (`errSecInteractionNotAllowed`) is what the Keychain answers from a restart of the iPhone until its first
    /// unlock. Any other refusal says as little about what is stored.
    @Test(arguments: [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed])
    func aKeychainThatRefusesTheReadIsUnavailableNotMissing(status: OSStatus) {
        let stores = Self.stores(reader: KeychainItemReader(copyMatching: { _, _ in status }))

        #expect(stores.accessToken.readAccessToken() == .unavailable)
        #expect(stores.refreshToken.readRefreshToken() == .unavailable)
        #expect(stores.session.readUserID() == .unavailable)
    }

    /// The callers that only need a value get none, as before.
    @Test func aKeychainThatRefusesTheReadLoadsNothing() {
        let stores = Self.stores(reader: KeychainItemReader(copyMatching: { _, _ in errSecInteractionNotAllowed }))

        #expect(stores.accessToken.loadAccessToken() == nil)
        #expect(stores.refreshToken.loadRefreshToken() == nil)
        #expect(stores.session.loadUserID() == nil)
    }

    // MARK: the log

    /// The lines the session module logs while a test holds its log.
    @MainActor
    private final class LoggedLines {
        var all: [String] = []
    }

    /// Runs `body` with the module's log pointed at the returned lines. There is no suspension inside, so no other
    /// test's line can land in between.
    private static func logged(during body: () -> Void) -> [String] {
        let lines = LoggedLines()
        let appSink = AuthLog.sink
        AuthLog.sink = { _, _, message in lines.all.append(message) }
        defer { AuthLog.sink = appSink }
        body()
        return lines.all
    }

    /// The token is read for every request, so a Keychain that stays unreadable would otherwise write a line a
    /// request and push everything else out of the app's log.
    @Test func aKeychainThatKeepsRefusingIsLoggedOncePerItem() {
        let stores = Self.stores(reader: KeychainItemReader(copyMatching: { _, _ in errSecInteractionNotAllowed }))

        let lines = Self.logged {
            for _ in 0..<3 {
                _ = stores.accessToken.readAccessToken()
                _ = stores.refreshToken.readRefreshToken()
            }
        }

        #expect(lines.count == 2)
        #expect(lines.filter { $0.contains("apiAccessToken") && $0.contains("-25308") }.count == 1)
        #expect(lines.filter { $0.contains("apiRefreshToken") && $0.contains("-25308") }.count == 1)
    }

    /// An item that could be read in between is a new failure the next time, and is logged again.
    @Test func anItemThatWasReadInBetweenIsLoggedAgain() {
        let refusing = KeychainItemReader(copyMatching: { _, _ in errSecInteractionNotAllowed })
        let empty = KeychainItemReader(copyMatching: { _, _ in errSecItemNotFound })
        var stores = Self.stores(reader: refusing)

        let lines = Self.logged {
            _ = stores.accessToken.readAccessToken()
            stores.accessToken.reader = empty
            _ = stores.accessToken.readAccessToken()
            stores.accessToken.reader = refusing
            _ = stores.accessToken.readAccessToken()
        }

        #expect(lines.count == 2)
    }

    /// Bytes that are not text can never be used as a token or an ID, so they count as nothing stored.
    @Test func storedBytesThatAreNotTextAreMissing() {
        let reader = KeychainItemReader(copyMatching: { _, result in
            result?.pointee = Data([0xFF, 0xFE, 0xFD]) as CFData
            return errSecSuccess
        })
        let stores = Self.stores(reader: reader)

        #expect(stores.accessToken.readAccessToken() == .missing)
        #expect(stores.refreshToken.readRefreshToken() == .missing)
        #expect(stores.session.readUserID() == .missing)
    }
}
