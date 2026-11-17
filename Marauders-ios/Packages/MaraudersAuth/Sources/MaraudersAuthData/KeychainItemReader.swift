//
//  KeychainItemReader.swift
//  MaraudersAuthData
//

import Foundation
import MaraudersAuth
import Security

/// Reads one generic-password item for the three Keychain stores, and keeps apart the two answers that are not a
/// value: nothing is stored, and the Keychain could not be read.
///
/// The items are `AfterFirstUnlock`. From a restart of the iPhone until its first unlock every read of them fails,
/// although they are there, and iOS can already have launched the app in the background in that time. So a read that
/// fails for any reason but "no such item" is `unavailable`, never `missing`.
struct KeychainItemReader: Sendable {
    /// `SecItemCopyMatching`. Tests replace it, because the Simulator's Keychain cannot be made to refuse a read.
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
        SecItemCopyMatching($0, $1)
    }

    /// The status last logged for each item that cannot be read. The token is read for every request, so a Keychain
    /// that stays unreadable is logged once an item, not once a request. An item that is read again starts over.
    private static var loggedFailures: [String: OSStatus] = [:]

    func read(service: String, account: String) -> StoredCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        let itemName = service + "/" + account
        switch status {
        case errSecSuccess:
            Self.loggedFailures[itemName] = nil
            // Bytes that are not text can never be used: the same as nothing stored.
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return .missing }
            return .value(value)
        case errSecItemNotFound:
            Self.loggedFailures[itemName] = nil
            return .missing
        default:
            if Self.loggedFailures[itemName] != status {
                Self.loggedFailures[itemName] = status
                // The status and the item's name, never a value.
                AuthLog.warning("auth", "keychain item \(account) cannot be read (status \(status))")
            }
            return .unavailable
        }
    }
}
