//
//  APIAccessTokenExpiryTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

struct APIAccessTokenExpiryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - valid and expired

    @Test func readsTheExpirationOfAWorkerShapedToken() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "iat": 1_797_408_000, "exp": 1_800_000_000])

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aTokenBeforeItsExpirationIsNotExpired() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "exp": 1_800_000_001])

        #expect(!APIAccessTokenExpiry.isExpired(token, now: now))
    }

    @Test func aTokenPastItsExpirationIsExpired() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "exp": 1_799_999_999])

        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }

    /// The Worker's `jwtVerify` rejects a token at its `exp`, not a second later.
    @Test func aTokenExpiringRightNowIsExpired() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "exp": 1_800_000_000])

        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }

    @Test func aFractionalExpirationIsKept() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "exp": 1_800_000_000.5])

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(!APIAccessTokenExpiry.isExpired(token, now: now))
        #expect(APIAccessTokenExpiry.isExpired(token, now: now.addingTimeInterval(0.5)))
    }

    @Test func aThirtyDayTokenFromTheWorkerIsValidForThirtyDays() {
        let thirtyDays: TimeInterval = 30 * 24 * 3_600
        let token = TestAccessToken.make(expiresIn: thirtyDays)

        #expect(!APIAccessTokenExpiry.isExpired(token))
        #expect(APIAccessTokenExpiry.isExpired(token, now: Date().addingTimeInterval(thirtyDays + 60)))
    }

    @Test func surroundingWhitespaceDoesNotHideTheExpiration() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "exp": 1_800_000_000])

        #expect(APIAccessTokenExpiry.expirationDate(of: "  \(token)\n") == Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A payload whose standard base64 would hold `+` and `/` is sent with `-` and `_`, and without padding.
    @Test func readsTheBase64URLAlphabetWithoutPadding() throws {
        let token = TestAccessToken.make(claims: ["sub": String(repeating: "???>>>", count: 6), "exp": 1_800_000_000])
        let payload = try #require(token.split(separator: ".").dropFirst().first)
        try #require(payload.contains("-") || payload.contains("_"), "the fixture must use the URL alphabet")
        try #require(!payload.contains("="))

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - cannot be read

    @Test(arguments: [
        "",
        "   ",
        "x",
        "only.two",
        "one.two.three.four",
        "aaa..ccc",
        "header.!!!.signature",
        "header.a.signature",
        "header.bm90LWpzb24.signature",
    ])
    func aStringThatIsNotAJWTCannotBeDated(token: String) {
        #expect(APIAccessTokenExpiry.expirationDate(of: token) == nil)
        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }

    @Test func anOpaqueTokenWithoutDotsCannotBeDated() {
        let token = String(repeating: "x", count: 40)

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == nil)
        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }

    @Test func aTokenWithoutExpCannotBeDated() {
        let token = TestAccessToken.make(claims: ["sub": "user-1", "iat": 1_797_408_000])

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == nil)
        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }

    @Test(arguments: [
        #"{"sub":"user-1","exp":"1900000000"}"#,
        #"{"sub":"user-1","exp":true}"#,
        #"{"sub":"user-1","exp":null}"#,
        #"{"sub":"user-1","exp":[1900000000]}"#,
        #"{"sub":"user-1","exp":{"seconds":1900000000}}"#,
        #"["exp",1900000000]"#,
        #"1900000000"#,
        #"{}"#,
        "",
    ])
    func anExpThatIsNotANumberCannotBeRead(payload: String) {
        let token = TestAccessToken.make(payload: Data(payload.utf8))

        #expect(APIAccessTokenExpiry.expirationDate(of: token) == nil)
        #expect(APIAccessTokenExpiry.isExpired(token, now: now))
    }
}
