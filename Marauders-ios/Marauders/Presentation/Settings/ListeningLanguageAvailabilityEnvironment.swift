//
//  ListeningLanguageAvailabilityEnvironment.swift
//  Marauders
//

import SwiftUI

extension EnvironmentValues {
    /// The check that tells which listening languages this iPhone cannot serve. `AppRootView` installs the real one from
    /// the composition root; `nil` until something does.
    @Entry var listeningLanguageAvailability: (any ListeningLanguageAvailability)? = nil
}
