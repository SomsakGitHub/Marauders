//
//  KeychainAPIRefreshTokenStore.swift
//  Marauders
//

import Foundation
import MaraudersAuth
import Security

/// The refresh token in the Keychain, beside the access token (same service, another account) and kept under the same
/// rule: nothing is read back before `InstallationSessionGuard` has cleared what a previous install left behind.
public struct KeychainAPIRefreshTokenStore: APIRefreshTokenStore {
    private let service: String
    private let account: String
    /// What reads the item. Tests replace it.
    var reader = KeychainItemReader()

    public init(service: String = "com.somsak.Marauders.auth", account: String = "apiRefreshToken") {
        self.service = service
        self.account = account
    }

    public func loadRefreshToken() -> String? {
        guard case .value(let token) = readRefreshToken() else { return nil }
        return token
    }

    public func readRefreshToken() -> StoredCredential {
        guard service != "com.somsak.Marauders.auth" || InstallationSessionGuard.isReady else { return .missing }
        return reader.read(service: service, account: account)
    }

    public func saveRefreshToken(_ token: String) throws {
        guard APIRefreshTokenFormat.isValid(token) else {
            throw KeychainAuthSessionStoreError.unexpectedStatus(errSecParam)
        }

        let encoded = Data(token.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (key, value) in attributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainAuthSessionStoreError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainAuthSessionStoreError.unexpectedStatus(updateStatus)
    }

    public func clearRefreshToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAuthSessionStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
