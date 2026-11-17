//
//  StoredCredential.swift
//  MaraudersAuth
//

import Foundation

/// What a session store answers when it is asked for the value it keeps.
///
/// `missing` and `unavailable` must never be taken for each other: a caller that ends the session because nothing is
/// stored would end a session that is still there if it did the same for a store it could not read.
public nonisolated enum StoredCredential: Sendable, Equatable {
    /// The value that is stored.
    case value(String)
    /// Nothing is stored.
    case missing
    /// The store could not be read right now, so whether something is stored is not known. The Keychain answers this
    /// way from a restart of the iPhone until its first unlock.
    case unavailable
}
