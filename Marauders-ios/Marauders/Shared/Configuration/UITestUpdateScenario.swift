//
//  UITestUpdateScenario.swift
//  Marauders
//

import Foundation

/// What the force-update gate hears under `UITEST` (docs/adr/012-force-update.md). A launch argument
/// next to `UITEST` picks it. With none, the gate has nothing to hear: it stays open and never uses the network, so
/// every other UI test sees the app.
enum UITestUpdateScenario: Equatable, Sendable {
    /// Nothing to say.
    case open
    /// `UITEST_UPDATE_REQUIRED`: a kept "required", so the Update screen is up from the start and stays up.
    case required
    /// `UITEST_UPDATE_REQUIRED_AFTER_REFRESH`: nothing is kept, so the window starts as the app; some seconds later the
    /// fresh answer says "required" and the window swaps to the Update screen by itself.
    case requiredAfterRefresh
    /// `UITEST_UPDATE_LIFTED_AFTER_REFRESH`: a "required" is kept, so the window starts on the Update screen; some
    /// seconds later the fresh answer says "no gate" and the window swaps to the app by itself.
    case liftedAfterRefresh

    init(arguments: [String]) {
        guard arguments.contains("UITEST") else {
            self = .open
            return
        }
        if arguments.contains("UITEST_UPDATE_REQUIRED_AFTER_REFRESH") {
            self = .requiredAfterRefresh
        } else if arguments.contains("UITEST_UPDATE_LIFTED_AFTER_REFRESH") {
            self = .liftedAfterRefresh
        } else if arguments.contains("UITEST_UPDATE_REQUIRED") {
            self = .required
        } else {
            self = .open
        }
    }
}
