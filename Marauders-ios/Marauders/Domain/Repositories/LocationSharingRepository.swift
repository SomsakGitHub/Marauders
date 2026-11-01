//
//  LocationSharingRepository.swift
//  Marauders
//

import Foundation

protocol LocationSharingRepository: Sendable {
    /// Whether the viewer shares their location, and the last locations of the mutual followers who share theirs.
    func friendLocations() async throws -> FriendLocations
    /// Turns the viewer's sharing on or off; returns what the Worker stored.
    func setSharing(_ enabled: Bool) async throws -> Bool
}
