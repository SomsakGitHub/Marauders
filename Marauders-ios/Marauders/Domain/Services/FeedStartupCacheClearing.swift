//
//  FeedStartupCacheClearing.swift
//  Marauders
//

import Foundation

/// The clips of the feed that this iPhone keeps for the next launch (see `FeedStartupCaching`), seen from the one thing
/// that must empty them: deleting the account.
protocol FeedStartupCacheClearing: Sendable {
    /// Removes every saved clip and the list of them, for every account and the guest. Best effort: it never throws.
    func removeAll() async
}
