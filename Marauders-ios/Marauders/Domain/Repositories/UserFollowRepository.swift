//
//  UserFollowRepository.swift
//  Marauders
//

import Foundation

protocol UserFollowRepository: Sendable {
    /// Follows the account with `handle`, or stops following it, as the signed-in viewer. Returns what the Worker
    /// stored, counts included.
    func setFollowing(_ following: Bool, handle: String) async throws -> UserFollowChange
}
