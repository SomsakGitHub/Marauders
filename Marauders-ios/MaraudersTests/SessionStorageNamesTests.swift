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

    @Test func theKeychainItemsKeepTheirServiceAndAccounts() {
        #expect(
            Self.names(of: KeychainAPIAccessTokenStore()) == ["service": Self.service, "account": "apiAccessToken"])
        #expect(
            Self.names(of: KeychainAPIRefreshTokenStore()) == ["service": Self.service, "account": "apiRefreshToken"])
        #expect(Self.names(of: KeychainAuthSessionStore()) == ["service": Self.service, "account": "appleUserID"])
    }

    @Test func aSavedTokenStaysOnThisDeviceAndIsReadableAfterTheFirstUnlock() throws {
        let service = "test.names." + UUID().uuidString
        let store = KeychainAPIAccessTokenStore(service: service)
        defer { try? store.clearAccessToken() }
        try store.saveAccessToken(String(repeating: "a", count: 32))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiAccessToken",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let accessible = (item as? [String: Any])?[kSecAttrAccessible as String] as? String
        #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
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
