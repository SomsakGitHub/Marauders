//
//  KeychainAPIAccessTokenStore.swift
//  Marauders
//

import Foundation
import MaraudersAuth
import Security

public struct KeychainAPIAccessTokenStore: APIAccessTokenStore {
    private let service: String
    private let account: String
    /// What reads the item. Tests replace it.
    var reader = KeychainItemReader()

    public init(service: String = "com.somsak.Marauders.auth", account: String = "apiAccessToken") {
        self.service = service
        self.account = account
    }

    public func loadAccessToken() -> String? {
        guard case .value(let token) = readAccessToken() else { return nil }
        return token
    }

    public func readAccessToken() -> StoredCredential {
        guard service != "com.somsak.Marauders.auth" || InstallationSessionGuard.isReady else { return .missing }
        return reader.read(service: service, account: account)
    }

    public func saveAccessToken(_ token: String) throws {
        guard APIAccessTokenFormat.isValid(token) else {
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

    public func clearAccessToken() throws {
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
