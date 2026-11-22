//
//  AppConfigRepository.swift
//  Marauders
//

import Foundation

protocol AppConfigRepository: Sendable {
    /// The last good answer, read without waiting. Nil when none is kept, or the kept one cannot be read.
    func cached() -> AppConfig?

    /// Asks once and keeps the answer. Nil when none could be had (no network, a timeout, nothing to ask): the caller
    /// then keeps what it has.
    func refresh() async -> AppConfig?
}
