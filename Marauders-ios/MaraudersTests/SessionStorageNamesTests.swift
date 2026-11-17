import Foundation
import Security
import Testing

@testable import Marauders
@testable import MaraudersAuthData

/// What must survive any change to the session code: a build that looks for the session under other names signs every
/// viewer out when it is installed over the build before it.
@MainActor
struct SessionStorageNamesTests {
    private static let service = "com.somsak.Marauders.auth"

    /// The text properties a store holds, private ones too.
    private static func names(of store: Any) -> [String: String] {
        var found: [String: String] = [:]
        for child in Mirror(reflecting: store).children {
            if let label = child.label, let value = child.value as? String { found[label] = value }
        }
        return found
    }

    /// The accessibility class of the item `service` holds for `account`, or nil when there is no such item.
    private static func accessibility(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    @Test func theKeychainItemsKeepTheirServiceAndAccounts() {
        #expect(
            Self.names(of: KeychainAPIAccessTokenStore()) == ["service": Self.service, "account": "apiAccessToken"])
        #expect(
            Self.names(of: KeychainAPIRefreshTokenStore()) == ["service": Self.service, "account": "apiRefreshToken"])
        #expect(Self.names(of: KeychainAuthSessionStore()) == ["service": Self.service, "account": "appleUserID"])
    }

    @Test func everySavedItemStaysOnThisDeviceAndIsReadableAfterTheFirstUnlock() throws {
        let service = "test.names." + UUID().uuidString
        let accessToken = KeychainAPIAccessTokenStore(service: service)
        let refreshToken = KeychainAPIRefreshTokenStore(service: service)
        let session = KeychainAuthSessionStore(service: service)
        defer {
            try? accessToken.clearAccessToken()
            try? refreshToken.clearRefreshToken()
            try? session.clear()
        }
        try accessToken.saveAccessToken(String(repeating: "a", count: 32))
        try refreshToken.saveRefreshToken(String(repeating: "r", count: 43))
        try session.saveUserID("001234.abcdef.5678")

        let expected = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        #expect(Self.accessibility(service: service, account: "apiAccessToken") == expected)
        #expect(Self.accessibility(service: service, account: "apiRefreshToken") == expected)
        #expect(Self.accessibility(service: service, account: "appleUserID") == expected)
    }

    @Test func theInstallMarkerKeepsItsPlace() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let expected = support.appendingPathComponent("Installation/session-initialized")
        #expect(try InstallationSessionGuard.markerURL().standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test func theTestsSeeTheGuardTheAppSetAtLaunch() {
        #expect(
            InstallationSessionGuard.isReady, "false: a second copy of the session code, or the launch check failed")
    }
}
