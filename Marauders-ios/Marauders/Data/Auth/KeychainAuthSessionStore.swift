//
//  KeychainAuthSessionStore.swift
//  Marauders
//

import Foundation
import Security

enum KeychainAuthSessionStoreError: Error {
    case unexpectedStatus(OSStatus)
}

struct KeychainAuthSessionStore: AuthSessionStore {
    private let service: String
    private let account: String

    init(service: String = "com.somsak.Marauders.auth", account: String = "appleUserID") {
        self.service = service
        self.account = account
    }

    func loadUserID() -> String? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data, let userID = String(data: data, encoding: .utf8) else {
            return nil
        }
        return userID
    }

    func saveUserID(_ userID: String) throws {
        guard Self.isValidUserID(userID) else {
            throw KeychainAuthSessionStoreError.unexpectedStatus(errSecParam)
        }

        let encoded = Data(userID.utf8)
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

    func clear() throws {
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

    static func isValidUserID(_ userID: String) -> Bool {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return false }
        return !trimmed.unicodeScalars.contains { $0.value < 32 }
    }
}
