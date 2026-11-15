import Foundation
import Testing

@testable import Marauders

@MainActor
struct RefreshTokenStoreTests {
    /// The shape of a real one: 43 base64url characters.
    private let first = String(repeating: "Ab-_0", count: 8) + "xyz"
    private let second = String(repeating: "Zy_-9", count: 8) + "abc"

    @Test func aSavedRefreshTokenComesBack() throws {
        let service = "test.refresh." + UUID().uuidString
        let store = KeychainAPIRefreshTokenStore(service: service)
        let accessTokens = KeychainAPIAccessTokenStore(service: service)
        defer {
            try? store.clearRefreshToken()
            try? accessTokens.clearAccessToken()
        }

        #expect(store.loadRefreshToken() == nil)
        try store.saveRefreshToken(first)
        #expect(store.loadRefreshToken() == first)

        try store.saveRefreshToken(second)
        #expect(store.loadRefreshToken() == second)

        // The access token lives beside it under another account and neither disturbs the other.
        try accessTokens.saveAccessToken(String(repeating: "x", count: 32))
        #expect(store.loadRefreshToken() == second)
        try store.clearRefreshToken()
        #expect(accessTokens.loadAccessToken() == String(repeating: "x", count: 32))

        #expect(store.loadRefreshToken() == nil)
        try store.clearRefreshToken()
    }

    @Test func aTokenOfTheWrongShapeIsRefused() throws {
        #expect(APIRefreshTokenFormat.isValid(first))
        #expect(APIRefreshTokenFormat.isValid(String(repeating: "a", count: 32)))
        #expect(APIRefreshTokenFormat.isValid(String(repeating: "a", count: 256)))

        let wrong = [
            "",
            String(repeating: "a", count: 31),
            String(repeating: "a", count: 257),
            String(repeating: "a", count: 42) + "+",
            String(repeating: "a", count: 42) + "=",
            String(repeating: "a", count: 42) + " ",
            String(repeating: "a", count: 42) + "\n",
            String(repeating: "a", count: 42) + "é",
        ]
        for token in wrong {
            #expect(!APIRefreshTokenFormat.isValid(token), "\(token.debugDescription) must be refused")
        }

        let store = KeychainAPIRefreshTokenStore(service: "test.refresh." + UUID().uuidString)
        #expect(throws: (any Error).self) { try store.saveRefreshToken("short") }
        #expect(store.loadRefreshToken() == nil)
    }

    @Test func theUITestSessionStartsWithoutARefreshToken() throws {
        let session = UITestRejectedSession()
        #expect(session.loadRefreshToken() == nil)

        try session.saveRefreshToken(first)
        #expect(session.loadRefreshToken() == first)

        try session.clearRefreshToken()
        #expect(session.loadRefreshToken() == nil)
    }
}
