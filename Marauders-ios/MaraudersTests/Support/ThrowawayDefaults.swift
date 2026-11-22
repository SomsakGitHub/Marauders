//
//  ThrowawayDefaults.swift
//  MaraudersTests
//

import Foundation

/// A UserDefaults suite of its own for one test, removed when the test lets go of it: no test touches `.standard` or
/// meets the keys of another test.
final class ThrowawayDefaults {
    let name = "tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
