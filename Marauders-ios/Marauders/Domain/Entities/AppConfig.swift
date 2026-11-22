//
//  AppConfig.swift
//  Marauders
//

import Foundation

/// What Firebase Remote Config says about the oldest build that may run (the parameters `minimum_build` and
/// `update_url`, docs/adr/012-force-update.md): the minimum build number, and where a build below it is sent to update.
/// 0 means no gate. Nothing checks what the console holds before it gets here, so `UpdateDecision` is the only check of
/// the link: a minimum above 0 without an official link stops no one.
struct AppConfig: Codable, Equatable, Sendable {
    let minimumBuild: Int
    let updateURL: URL?
}
